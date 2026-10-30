/* Synthetic collector regression: no live processes, names, or sensors read. */
#include <assert.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>

enum { FIXTURE_PROCESS_COUNT = 12 };
typedef struct {
    uint64_t ticks, start, memory, weight;
    int unreadable, overflow;
    int parent;
    const char *path, *command;
} FixtureProcess;
static FixtureProcess fixture_processes[FIXTURE_PROCESS_COUNT + 1];
static int fixture_generation, fixture_list_failure;
static int fixture_name_calls, fixture_names_by_pid[FIXTURE_PROCESS_COUNT + 1];

static int fixture_listpids(uint32_t type, uint32_t typeinfo, void *buffer,
                             int buffer_size) {
    assert(type == PROC_ALL_PIDS && typeinfo == 0);
    if (fixture_list_failure) return 0;
    int bytes = FIXTURE_PROCESS_COUNT * (int)sizeof(pid_t);
    if (!buffer) return bytes;
    assert(buffer_size > bytes);
    /* Unsorted enumeration also exercises the previous-sample binary search. */
    for (int index = 0; index < FIXTURE_PROCESS_COUNT; ++index) {
        ((pid_t *)buffer)[index] = FIXTURE_PROCESS_COUNT - index;
    }
    return bytes;
}

static int fixture_rusage(int pid, int flavor, rusage_info_t *buffer) {
    assert(pid > 0 && pid <= FIXTURE_PROCESS_COUNT && flavor == RUSAGE_INFO_V2);
    FixtureProcess *process = &fixture_processes[pid];
    if (process->unreadable) return -1;
    struct rusage_info_v2 *usage = (struct rusage_info_v2 *)buffer;
    memset(usage, 0, sizeof(*usage));
    usage->ri_user_time = process->overflow ? UINT64_MAX : process->ticks;
    usage->ri_system_time = process->overflow ? 1 : 0;
    usage->ri_proc_start_abstime = process->start;
    usage->ri_phys_footprint = process->memory;
    return 0;
}

static int fixture_name(int pid, void *buffer, uint32_t buffer_size) {
    assert(pid > 0 && pid <= FIXTURE_PROCESS_COUNT && buffer_size == 128);
    ++fixture_name_calls;
    assert(++fixture_names_by_pid[pid] == 1);
    if (pid == 12) return 0;             /* A process can exit after sampling. */
    if (pid == 11) { ((char *)buffer)[0] = '\0'; return 1; }
    if (pid == 10) { memset(buffer, 'x', buffer_size); return (int)buffer_size; }
    return snprintf(buffer, buffer_size, "fixture-%d", pid);
}

static int fixture_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int size) {
    assert(pid > 0 && pid <= FIXTURE_PROCESS_COUNT && flavor == PROC_PIDTBSDINFO && arg == 0);
    assert(size == sizeof(struct proc_bsdinfo));
    struct proc_bsdinfo *info = buffer;
    memset(info, 0, sizeof(*info));
    info->pbi_ppid = fixture_processes[pid].parent;
    if (fixture_processes[pid].command) snprintf(info->pbi_comm, sizeof(info->pbi_comm), "%s", fixture_processes[pid].command);
    return size;
}
static int fixture_pidpath(int pid, void *buffer, uint32_t size) {
    assert(pid > 0 && pid <= FIXTURE_PROCESS_COUNT);
    const char *path = fixture_processes[pid].path;
    return path ? snprintf(buffer, size, "%s", path) : 0;
}

static int fixture_clock(clockid_t clock, struct timespec *time) {
    assert(clock == CLOCK_MONOTONIC);
    time->tv_sec = fixture_generation + 1;
    time->tv_nsec = 0;
    return 0;
}

static int fixture_sysctl(const char *name, void *value, size_t *size,
                           void *new_value, size_t new_size) {
    assert(strcmp(name, "hw.logicalcpu") == 0 && *size == sizeof(int));
    assert(!new_value && new_size == 0);
    *(int *)value = 1;
    return 0;
}

static kern_return_t fixture_timebase(mach_timebase_info_t timebase) {
    timebase->numer = 1;
    timebase->denom = 1;
    return KERN_SUCCESS;
}

#define proc_pidinfo fixture_pidinfo
#define proc_pidpath fixture_pidpath
#define proc_listpids fixture_listpids
#define proc_pid_rusage fixture_rusage
#define proc_name fixture_name
#define clock_gettime fixture_clock
#define sysctlbyname fixture_sysctl
#define mach_timebase_info fixture_timebase
#include "../../Sources/ResourceMetrics.c"

static void prepare(void) {
    mt_process_metrics_reset();
    memset(fixture_processes, 0, sizeof(fixture_processes));
    fixture_generation = fixture_list_failure = 0;
    for (int pid = 1; pid <= FIXTURE_PROCESS_COUNT; ++pid) {
        fixture_processes[pid].start = (uint64_t)pid + 100;
        fixture_processes[pid].memory = (uint64_t)pid * 100;
        fixture_processes[pid].weight = 1;
    }
    fixture_processes[2].weight = 9;
    fixture_processes[5].weight = 8;
    fixture_processes[12].weight = 7;
}

static MTProcessMetrics sample(void) {
    ++fixture_generation;
    fixture_name_calls = 0;
    memset(fixture_names_by_pid, 0, sizeof(fixture_names_by_pid));
    for (int pid = 1; pid <= FIXTURE_PROCESS_COUNT; ++pid) {
        fixture_processes[pid].ticks += fixture_processes[pid].weight * 100000000;
    }
    MTProcessMetrics result = mt_process_metrics_sample();
    assert(fixture_name_calls <= 6);
    return result;
}

static void check_names(const MTProcessMetrics *metrics) {
    for (int list = 0; list < 2; ++list) {
        const MTProcessEntry *entries = list ? metrics->cpu_top : metrics->memory_top;
        int count = list ? metrics->cpu_count : metrics->memory_count;
        for (int index = 0; index < count; ++index) {
            const MTProcessEntry *entry = &entries[index];
            assert(entry->name[0] && entry->name[127] == '\0');
            if (entry->pid == 12) assert(strcmp(entry->name, "PID 12") == 0);
            if (entry->pid == 11) assert(strcmp(entry->name, "PID 11") == 0);
        }
    }
}

static void grouped_checks(void) {
    prepare();
    /* App total beats every individual process. Nested helpers share outer app;
     * inherited CLI children group, shells stop unrelated jobs, identical names
     * in separate app paths and unowned Java processes remain separate. */
    fixture_processes[2].path = "/Applications/Example.app/Contents/MacOS/Example";
    fixture_processes[3].path = "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper";
    fixture_processes[4].parent = 3;
    fixture_processes[5].path = "/Other/Example.app/Contents/MacOS/Example";
    fixture_processes[6].parent = 2;
    fixture_processes[6].command = "zsh";
    fixture_processes[7].parent = 6;
    fixture_processes[8].parent = 2;
    fixture_processes[8].start = 1; /* Parent is newer: reject possible PID reuse. */
    fixture_processes[9].parent = 10;
    fixture_processes[10].parent = 9; /* Cycles are bounded. */
    for (int pid = 1; pid <= FIXTURE_PROCESS_COUNT; ++pid) {
        fixture_processes[pid].memory = 10;
        fixture_processes[pid].weight = 1;
    }
    fixture_processes[2].memory = 1000;
    fixture_processes[3].memory = 900;
    fixture_processes[4].memory = 800;
    fixture_processes[5].memory = 2000;
    fixture_processes[7].memory = 1800;
    MTProcessMetrics first = sample();
    assert(!first.cpu_ready && first.memory_top[0].pid == 2);
    assert(first.memory_top[0].memory_bytes == 2700 && first.memory_top[0].process_count == 3);
    assert(strcmp(first.memory_top[0].name, "Example") == 0);
    MTProcessMetrics next = sample();
    assert(next.cpu_top[0].pid == 2 && next.cpu_top[0].cpu_usage_percent > 29.9);
    assert(next.memory_top[1].pid == 5 && next.memory_top[1].process_count == 1);
    assert(next.memory_top[2].pid == 7); /* Not swallowed by Terminal's shell. */
    assert(mt_process_group_members(2, NULL, 0) == 3);
    MTProcessEntry members[3] = {0};
    /* Allow name-on-demand checks separately from the old top-only lookup budget. */
    memset(fixture_names_by_pid, 0, sizeof(fixture_names_by_pid));
    assert(mt_process_group_members(2, members, 3) == 3);
    assert(members[0].pid == 2 && members[1].pid == 3 && members[2].pid == 4);
    assert(members[2].memory_bytes == 800 && members[2].cpu_valid);
    assert(mt_process_group_members(2, members, 1) == 3); /* Bounded copy reports full count. */
    mt_process_metrics_reset();
    assert(mt_process_group_members(2, NULL, 0) == 0);
    /* Same PID can exec a different app without restarting: no stale path cache. */
    (void)sample();
    fixture_processes[3].path = "/Applications/Separate.app/Contents/MacOS/Helper";
    MTProcessMetrics exec = sample();
    assert(exec.memory_top[0].pid == 5);
    assert(mt_process_group_members(3, NULL, 0) == 2);
    mt_process_metrics_reset();
}

int main(void) {
    prepare();
    MTProcessMetrics first = sample();
    assert(first.valid && !first.cpu_ready && first.cpu_count == 0);
    assert(first.readable_count == 12 && first.memory_count == 3);
    assert(first.memory_top[0].pid == 12 && first.memory_top[1].pid == 11 &&
           first.memory_top[2].pid == 10 && fixture_name_calls == 3);
    check_names(&first);
    MTProcessMetrics mixed = sample();
    assert(mixed.cpu_ready && mixed.cpu_count == 3 && fixture_name_calls == 5);
    assert(mixed.cpu_top[0].pid == 2 && mixed.cpu_top[1].pid == 5 &&
           mixed.cpu_top[2].pid == 12);
    assert(mixed.cpu_top[0].cpu_usage_percent == 90.0);
    assert(strcmp(mixed.cpu_top[2].name, mixed.memory_top[0].name) == 0);
    check_names(&mixed);

    /* A reused PID establishes a new CPU baseline while remaining in memory. */
    ++fixture_processes[2].start;
    fixture_processes[5].ticks = 0;
    MTProcessMetrics recycled = sample();
    assert(recycled.cpu_top[0].pid == 12 && recycled.cpu_top[1].pid == 1 &&
           recycled.cpu_top[2].pid == 3);
    assert(recycled.memory_top[0].pid == 12);
    fixture_processes[7].unreadable = 1;
    fixture_processes[8].overflow = 1;
    MTProcessMetrics skipped = sample();
    assert(skipped.readable_count == 10 && skipped.skipped_count == 2);

    /* Complete overlap resolves each name once; ties still use ascending PID. */
    prepare();
    for (int pid = 1; pid <= FIXTURE_PROCESS_COUNT; ++pid) {
        fixture_processes[pid].weight = pid > 9 ? (uint64_t)(pid - 9) : 0;
    }
    (void)sample();
    MTProcessMetrics overlap = sample();
    assert(fixture_name_calls == 3 && overlap.cpu_top[0].pid == 12 &&
           overlap.cpu_top[1].pid == 11 && overlap.cpu_top[2].pid == 10);
    check_names(&overlap);
    for (int pid = 1; pid <= FIXTURE_PROCESS_COUNT; ++pid) {
        fixture_processes[pid].weight = 1;
    }
    MTProcessMetrics distinct = sample();
    assert(fixture_name_calls == 6 && distinct.cpu_top[0].pid == 1 &&
           distinct.cpu_top[1].pid == 2 && distinct.cpu_top[2].pid == 3);

    fixture_list_failure = 1;
    MTProcessMetrics unavailable = sample();
    assert(!unavailable.valid && fixture_name_calls == 0);
    fixture_list_failure = 0;
    MTProcessMetrics recovered = sample();
    assert(recovered.valid && !recovered.cpu_ready && fixture_name_calls == 3);
    mt_process_metrics_reset();
    MTProcessMetrics reset = sample();
    assert(reset.valid && !reset.cpu_ready && fixture_name_calls == 3);
    mt_process_metrics_reset();
    grouped_checks();
    puts("Synthetic process ranking passed: app sums, nested bundles, verified ancestry, shell boundaries, separate paths, cycles, PID reuse/exec, member drill-down; first/reset/failure baselines, PID reuse,"
         " counter rollback, skips, tie order, name fallbacks and NUL termination;"
         " name lookups=3/5/6 for overlapping/mixed/distinct top lists.");
    return 0;
}
