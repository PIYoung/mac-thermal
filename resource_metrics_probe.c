/* Bounded live integration check; no process names/arguments are printed.
 * Build alongside ResourceMetrics.c and DiskMetrics.c, linking IOKit and
 * CoreFoundation. Takes four seconds; does not create a workload or data file. */
#include "ResourceMetrics.h"
#include "DiskMetrics.h"

#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

static int failures;

static void check(int condition, const char *description) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", description);
        ++failures;
    }
}

static double seconds(struct timespec time) {
    return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}

static double cpu_seconds(struct rusage usage) {
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
           usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

static void check_entries(const MTProcessEntry *entries, int count, int cpu) {
    check(count >= 0 && count <= 3, "top list count in 0...3");
    for (int index = 0; index < count && index < 3; ++index) {
        check(entries[index].pid > 0, "top entry has a PID");
        check(memchr(entries[index].name, '\0', sizeof(entries[index].name)) != NULL,
              "top entry name is terminated");
        if (cpu) {
            check(isfinite(entries[index].cpu_usage_percent) &&
                  entries[index].cpu_usage_percent >= 0 &&
                  entries[index].cpu_usage_percent <= 100,
                  "CPU percentage is finite whole-machine 0...100");
            if (index > 0) {
                check(entries[index - 1].cpu_usage_percent >=
                      entries[index].cpu_usage_percent,
                      "CPU top entries descend");
            }
        } else if (index > 0) {
            check(entries[index - 1].memory_bytes >= entries[index].memory_bytes,
                  "memory top entries descend");
        }
    }
}

int main(void) {
    struct rusage cpu_begin, cpu_end;
    struct timespec start, end;
    getrusage(RUSAGE_SELF, &cpu_begin);
    clock_gettime(CLOCK_MONOTONIC, &start);
    mt_process_metrics_reset();
    for (int iteration = 0; iteration < 5; ++iteration) {
        if (iteration > 0) usleep(1000000);
        struct timespec sample_begin, sample_end;
        clock_gettime(CLOCK_MONOTONIC, &sample_begin);
        MTMemoryMetrics memory = mt_memory_metrics_sample();
        MTProcessMetrics processes = mt_process_metrics_sample();
        MTDiskMetrics disk = mt_disk_metrics_sample();
        clock_gettime(CLOCK_MONOTONIC, &sample_end);

        check(memory.valid && memory.total_bytes > 0, "physical memory readable");
        check(memory.used_bytes <= memory.total_bytes, "used memory <= physical memory");
        check(memory.compressed_bytes <= memory.total_bytes,
              "compressor storage <= physical memory");
        if (memory.pressure_valid) {
            check(memory.pressure_level >= 0 && memory.pressure_level <= 2,
                  "kernel pressure state in 0...2");
        }
        check(processes.valid && processes.readable_count > 0,
              "at least one process is readable");
        check(processes.readable_count >= processes.memory_count,
              "memory entries are drawn from readable processes");
        check_entries(processes.cpu_top, processes.cpu_count, 1);
        check_entries(processes.memory_top, processes.memory_count, 0);
        if (iteration == 0) {
            check(!processes.cpu_ready && processes.cpu_count == 0,
                  "first process interval establishes baseline");
            check(!disk.io_valid, "first disk interval establishes baseline");
        } else {
            check(processes.cpu_ready && processes.cpu_count > 0,
                  "subsequent process interval is ready");
            check(disk.io_valid, "subsequent disk interval is valid");
        }
        check(disk.capacity_valid && disk.total_bytes > 0,
              "SSD capacity readable");
        check(disk.available_bytes <= disk.total_bytes,
              "available capacity <= total capacity");
        check(disk.device_count > 0, "internal physical SSD selected");
        if (disk.io_valid) {
            check(isfinite(disk.read_bytes_per_second) &&
                  disk.read_bytes_per_second >= 0 &&
                  isfinite(disk.write_bytes_per_second) &&
                  disk.write_bytes_per_second >= 0,
                  "IO rates are finite and nonnegative, including valid zero");
        }
        printf("sample=%d sampler_ms=%.3f memory_valid=%d pressure_valid=%d "
               "processes=%d skipped=%d cpu_ready=%d disk_devices=%d disk_ready=%d\n",
               iteration + 1, (seconds(sample_end) - seconds(sample_begin)) * 1000,
               memory.valid, memory.pressure_valid, processes.readable_count,
               processes.skipped_count, processes.cpu_ready, disk.device_count,
               disk.io_valid);
    }
    mt_process_metrics_reset();
    MTProcessMetrics reset = mt_process_metrics_sample();
    check(reset.valid && !reset.cpu_ready && reset.cpu_count == 0,
          "reset clears CPU history without losing memory entries");
    check(reset.memory_count > 0, "memory top remains available after reset");
    mt_process_metrics_reset();
    clock_gettime(CLOCK_MONOTONIC, &end);
    getrusage(RUSAGE_SELF, &cpu_end);
    printf("bounded_probe elapsed_s=%.3f sampler_cpu_ms=%.3f failures=%d\n",
           seconds(end) - seconds(start),
           (cpu_seconds(cpu_end) - cpu_seconds(cpu_begin)) * 1000, failures);
    return failures != 0;
}
