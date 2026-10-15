#ifndef MAC_THERMAL_RESOURCE_METRICS_H
#define MAC_THERMAL_RESOURCE_METRICS_H

#include <stdint.h>

typedef struct {
    uint64_t total_bytes;
    uint64_t used_bytes;
    uint64_t compressed_bytes;
    uint64_t swap_used_bytes;
    /* -1 unavailable, 0 normal, 1 warning, 2 critical. */
    int pressure_level;
    int valid;
    int pressure_valid;
    int swap_valid;
} MTMemoryMetrics;

typedef struct {
    int32_t pid;
    char name[128];
    /* Percentage of the whole machine, rather than of one CPU core. */
    double cpu_usage_percent;
    /* The process's physical footprint, not its virtual address space. */
    uint64_t memory_bytes;
} MTProcessEntry;

typedef struct {
    MTProcessEntry cpu_top[3];
    MTProcessEntry memory_top[3];
    int cpu_count;
    int memory_count;
    int readable_count;
    int skipped_count;
    int valid;
    int cpu_ready;
} MTProcessMetrics;

MTMemoryMetrics mt_memory_metrics_sample(void);
MTProcessMetrics mt_process_metrics_sample(void);
/* Clears CPU history; the next successful sample only establishes a baseline. */
void mt_process_metrics_reset(void);

#endif
