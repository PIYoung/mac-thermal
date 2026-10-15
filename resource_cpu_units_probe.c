#include "ResourceMetrics.h"
#include <assert.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

/* A short, bounded workload verifies the rusage CPU counter's timebase against
 * the C runtime process CPU clock without launching or touching another app. */
static void check_cpu_units(void) {
    struct rusage_info_v2 before = {0}, after = {0};
    assert(proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&before) == 0);
    clock_t cpu_started = clock();
    struct timespec first, now;
    clock_gettime(CLOCK_MONOTONIC, &first);
    volatile unsigned long accumulator = 1;
    do {
        for (int i = 0; i < 20000; ++i) accumulator = accumulator * 1664525 + 1013904223;
        clock_gettime(CLOCK_MONOTONIC, &now);
    } while ((double)(now.tv_sec - first.tv_sec) + (double)(now.tv_nsec - first.tv_nsec) / 1e9 < 0.4);
    clock_t cpu_ended = clock();
    assert(proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&after) == 0);
    mach_timebase_info_data_t timebase = {0};
    assert(mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom > 0);
    uint64_t delta = after.ri_user_time + after.ri_system_time - before.ri_user_time - before.ri_system_time;
    double converted_seconds = (double)delta * timebase.numer / timebase.denom / 1e9;
    double clock_seconds = (double)(cpu_ended - cpu_started) / CLOCKS_PER_SEC;
    assert(clock_seconds > 0);
    double agreement = converted_seconds / clock_seconds;
    assert(agreement > 0.9 && agreement < 1.1);
    printf("CPU timebase=%u/%u; rusage-to-process-clock ratio=%.4f; CPU clock seconds=%.3f; bounded-workload=passed\n",
           timebase.numer, timebase.denom, agreement, clock_seconds);
}

static void check_processes(MTProcessMetrics metrics) {
    assert(metrics.valid);
    assert(metrics.readable_count > 0);
    assert(metrics.cpu_count >= 0 && metrics.cpu_count <= 3);
    assert(metrics.memory_count > 0 && metrics.memory_count <= 3);
    for (int i = 0; i < metrics.cpu_count; ++i) {
        assert(metrics.cpu_top[i].pid > 0 && metrics.cpu_top[i].name[0]);
        double cpu = metrics.cpu_top[i].cpu_usage_percent;
        assert(isfinite(cpu) && cpu >= 0 && cpu <= 100);
        if (i) assert(metrics.cpu_top[i - 1].cpu_usage_percent >= cpu);
    }
    for (int i = 0; i < metrics.memory_count; ++i) {
        assert(metrics.memory_top[i].pid > 0 && metrics.memory_top[i].name[0]);
        if (i) assert(metrics.memory_top[i - 1].memory_bytes >= metrics.memory_top[i].memory_bytes);
    }
}

int main(void) {
    MTMemoryMetrics memory = mt_memory_metrics_sample();
    printf("memory valid=%d total=%llu used=%llu compressed=%llu swap_valid=%d swap=%llu pressure_valid=%d pressure=%d\n",
           memory.valid, (unsigned long long)memory.total_bytes,
           (unsigned long long)memory.used_bytes, (unsigned long long)memory.compressed_bytes,
           memory.swap_valid, (unsigned long long)memory.swap_used_bytes,
           memory.pressure_valid, memory.pressure_level);
    assert(memory.valid && memory.total_bytes > 0);
    assert(memory.used_bytes <= memory.total_bytes && memory.compressed_bytes <= memory.total_bytes);
    assert(!memory.pressure_valid || (memory.pressure_level >= 0 && memory.pressure_level <= 2));
    MTProcessMetrics first = mt_process_metrics_sample();
    check_processes(first);
    assert(!first.cpu_ready && !first.cpu_count);
    struct timespec pause = {.tv_sec = 1, .tv_nsec = 200000000};
    nanosleep(&pause, NULL);
    MTProcessMetrics second = mt_process_metrics_sample();
    check_processes(second);
    assert(second.cpu_ready && second.cpu_count > 0);
    printf("process first readable=%d skipped=%d cpu_ready=%d; second readable=%d skipped=%d cpu_ready=%d top_cpu=%.2f top_memory=%llu\n",
           first.readable_count, first.skipped_count, first.cpu_ready,
           second.readable_count, second.skipped_count, second.cpu_ready,
           second.cpu_top[0].cpu_usage_percent, (unsigned long long)second.memory_top[0].memory_bytes);
    mt_process_metrics_reset();
    MTProcessMetrics reset = mt_process_metrics_sample();
    check_processes(reset);
    assert(!reset.cpu_ready && !reset.cpu_count);
    mt_process_metrics_reset();
    check_cpu_units();
    puts("sanity=passed; reset=passed; process names omitted");
    return 0;
}
