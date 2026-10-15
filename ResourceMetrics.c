#include "ResourceMetrics.h"

#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <time.h>

enum { MT_PROCESS_LIMIT = 32768, MT_PROCESS_LIST_PADDING = 256 };

typedef struct {
    int32_t pid;
    uint64_t start_time;
    uint64_t cpu_ticks;
    struct timespec sampled_at;
} MTProcessBaseline;

static pthread_mutex_t mt_process_mutex = PTHREAD_MUTEX_INITIALIZER;
static MTProcessBaseline *mt_previous_processes;
static size_t mt_previous_process_count;

MTMemoryMetrics mt_memory_metrics_sample(void) {
    MTMemoryMetrics metrics = {0};
    metrics.pressure_level = -1;

    /* This is the kernel's memory-pressure state, not a used/total heuristic.
     * VM_PRESSURE_{NORMAL,WARNING,CRITICAL} are 1, 2, and 4 respectively. */
    int pressure = 0;
    size_t pressure_size = sizeof(pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure,
                     &pressure_size, NULL, 0) == 0 &&
        pressure_size == sizeof(pressure)) {
        if (pressure == 1 || pressure == 2 || pressure == 4) {
            metrics.pressure_level = pressure == 1 ? 0 : pressure == 2 ? 1 : 2;
            metrics.pressure_valid = 1;
        }
    }

    struct xsw_usage swap = {0};
    size_t swap_size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &swap_size, NULL, 0) == 0 &&
        swap_size == sizeof(swap)) {
        metrics.swap_used_bytes = swap.xsu_used;
        metrics.swap_valid = 1;
    }

    size_t total_size = sizeof(metrics.total_bytes);
    if (sysctlbyname("hw.memsize", &metrics.total_bytes, &total_size,
                     NULL, 0) != 0 ||
        total_size != sizeof(metrics.total_bytes) || metrics.total_bytes == 0) {
        return metrics;
    }

    vm_statistics64_data_t statistics = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_size_t page_size = 0;
    mach_port_t host = mach_host_self();
    kern_return_t page_result = host_page_size(host, &page_size);
    kern_return_t result = host_statistics64(host, HOST_VM_INFO64,
                                            (host_info64_t)&statistics, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (page_result != KERN_SUCCESS || result != KERN_SUCCESS ||
        page_size == 0 || count < HOST_VM_INFO64_REV1_COUNT) {
        return metrics;
    }

    /* Non-cache physical usage: active + inactive + wired + compressor,
     * subtracting purgeable and file-backed pages. This is an explicit VM
     * accounting estimate; it is not claimed to match Activity Monitor byte
     * for byte. Compressed bytes are the physical compressor storage size,
     * not total_uncompressed_pages_in_compressor. */
    uint64_t occupied_pages = (uint64_t)statistics.active_count +
        statistics.inactive_count + statistics.wire_count +
        statistics.compressor_page_count;
    uint64_t reusable_pages = (uint64_t)statistics.purgeable_count +
        statistics.external_page_count;
    uint64_t used_pages = occupied_pages > reusable_pages ?
        occupied_pages - reusable_pages : 0;
    uint64_t maximum_pages = metrics.total_bytes / page_size;
    metrics.used_bytes = used_pages >= maximum_pages ? metrics.total_bytes :
        used_pages * page_size;
    uint64_t compressed_pages = statistics.compressor_page_count;
    metrics.compressed_bytes = compressed_pages >= maximum_pages ?
        metrics.total_bytes : compressed_pages * page_size;
    metrics.valid = 1;
    return metrics;
}

static int mt_baseline_compare(const void *left, const void *right) {
    const MTProcessBaseline *a = left;
    const MTProcessBaseline *b = right;
    return (a->pid > b->pid) - (a->pid < b->pid);
}

static const MTProcessBaseline *mt_find_previous(int32_t pid) {
    if (mt_previous_process_count == 0) {
        return NULL;
    }
    MTProcessBaseline key = {0};
    key.pid = pid;
    return bsearch(&key, mt_previous_processes, mt_previous_process_count,
                   sizeof(*mt_previous_processes), mt_baseline_compare);
}

static int mt_entry_precedes(const MTProcessEntry *a, const MTProcessEntry *b,
                             int compare_cpu) {
    if (compare_cpu && a->cpu_usage_percent != b->cpu_usage_percent) {
        return a->cpu_usage_percent > b->cpu_usage_percent;
    }
    if (!compare_cpu && a->memory_bytes != b->memory_bytes) {
        return a->memory_bytes > b->memory_bytes;
    }
    return a->pid < b->pid;
}

static void mt_insert_top(MTProcessEntry top[3], int *count,
                          const MTProcessEntry *entry, int compare_cpu) {
    int position = 0;
    while (position < *count &&
           !mt_entry_precedes(entry, &top[position], compare_cpu)) {
        ++position;
    }
    if (position >= 3) {
        return;
    }
    int last = *count < 3 ? *count : 2;
    for (int index = last; index > position; --index) {
        top[index] = top[index - 1];
    }
    top[position] = *entry;
    if (*count < 3) {
        ++*count;
    }
}

static void mt_clear_process_baseline(void) {
    free(mt_previous_processes);
    mt_previous_processes = NULL;
    mt_previous_process_count = 0;
}

void mt_process_metrics_reset(void) {
    pthread_mutex_lock(&mt_process_mutex);
    mt_clear_process_baseline();
    pthread_mutex_unlock(&mt_process_mutex);
}

MTProcessMetrics mt_process_metrics_sample(void) {
    MTProcessMetrics metrics = {0};
    pthread_mutex_lock(&mt_process_mutex);

    int required_bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (required_bytes <= 0) {
        mt_clear_process_baseline();
        pthread_mutex_unlock(&mt_process_mutex);
        return metrics;
    }
    size_t capacity = (size_t)required_bytes / sizeof(pid_t) +
        MT_PROCESS_LIST_PADDING;
    if (capacity > MT_PROCESS_LIMIT) {
        capacity = MT_PROCESS_LIMIT;
    }
    pid_t *pids = calloc(capacity, sizeof(*pids));
    MTProcessBaseline *current = calloc(capacity, sizeof(*current));
    if (!pids || !current) {
        free(pids);
        free(current);
        mt_clear_process_baseline();
        pthread_mutex_unlock(&mt_process_mutex);
        return metrics;
    }
    int buffer_bytes = (int)(capacity * sizeof(*pids));
    int returned_bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, buffer_bytes);
    if (returned_bytes <= 0 || returned_bytes > buffer_bytes ||
        returned_bytes % (int)sizeof(*pids) != 0 ||
        returned_bytes == buffer_bytes) {
        /* Do not silently label a truncated process list as a system top 3. */
        free(pids);
        free(current);
        mt_clear_process_baseline();
        pthread_mutex_unlock(&mt_process_mutex);
        return metrics;
    }

    int logical_cpus = 0;
    size_t cpu_size = sizeof(logical_cpus);
    if (sysctlbyname("hw.logicalcpu", &logical_cpus, &cpu_size, NULL, 0) != 0 ||
        cpu_size != sizeof(logical_cpus) || logical_cpus < 1 ||
        logical_cpus > 1024) {
        logical_cpus = 0;
    }
    mach_timebase_info_data_t timebase = {0};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS ||
        timebase.numer == 0 || timebase.denom == 0) {
        logical_cpus = 0;
    }

    size_t current_count = 0;
    size_t pid_count = (size_t)returned_bytes / sizeof(*pids);
    for (size_t index = 0; index < pid_count; ++index) {
        if (pids[index] <= 0) {
            continue;
        }
        struct rusage_info_v2 usage = {0};
        struct timespec sampled_at;
        if (proc_pid_rusage(pids[index], RUSAGE_INFO_V2,
                            (rusage_info_t *)&usage) != 0 ||
            clock_gettime(CLOCK_MONOTONIC, &sampled_at) != 0 ||
            UINT64_MAX - usage.ri_user_time < usage.ri_system_time) {
            ++metrics.skipped_count;
            continue;
        }
        MTProcessBaseline *sample = &current[current_count++];
        sample->pid = pids[index];
        sample->start_time = usage.ri_proc_start_abstime;
        sample->cpu_ticks = usage.ri_user_time + usage.ri_system_time;
        sample->sampled_at = sampled_at;

        MTProcessEntry entry = {0};
        entry.pid = pids[index];
        entry.memory_bytes = usage.ri_phys_footprint;
        /* Collect only a process name, never its path, command line or args. */
        if (proc_name(pids[index], entry.name, sizeof(entry.name)) <= 0 ||
            entry.name[0] == '\0') {
            snprintf(entry.name, sizeof(entry.name), "PID %d", pids[index]);
        }
        entry.name[sizeof(entry.name) - 1] = '\0';
        ++metrics.readable_count;
        mt_insert_top(metrics.memory_top, &metrics.memory_count, &entry, 0);

        const MTProcessBaseline *previous = mt_find_previous(sample->pid);
        if (!previous || sample->start_time == 0 ||
            previous->start_time != sample->start_time ||
            sample->cpu_ticks < previous->cpu_ticks ||
            logical_cpus == 0) {
            continue;
        }
        double elapsed = (double)(sampled_at.tv_sec - previous->sampled_at.tv_sec) +
            (double)(sampled_at.tv_nsec - previous->sampled_at.tv_nsec) / 1e9;
        if (elapsed <= 0.0) {
            continue;
        }
        /* ri_user_time/system_time are Mach absolute-time units. Converting
         * with the machine's timebase is essential on Apple silicon; assuming
         * nanoseconds would undercount CPU on the current hardware. */
        double cpu_seconds = (double)(sample->cpu_ticks - previous->cpu_ticks) *
            (double)timebase.numer / (double)timebase.denom / 1e9;
        double percent = cpu_seconds / elapsed / logical_cpus * 100.0;
        entry.cpu_usage_percent = percent > 100.0 ? 100.0 : percent;
        mt_insert_top(metrics.cpu_top, &metrics.cpu_count, &entry, 1);
    }
    free(pids);
    qsort(current, current_count, sizeof(*current), mt_baseline_compare);
    mt_clear_process_baseline();
    mt_previous_processes = current;
    mt_previous_process_count = current_count;
    metrics.valid = metrics.readable_count > 0;
    metrics.cpu_ready = metrics.cpu_count > 0;
    pthread_mutex_unlock(&mt_process_mutex);
    return metrics;
}
