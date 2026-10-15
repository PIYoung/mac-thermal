#ifndef MT_DISK_METRICS_H
#define MT_DISK_METRICS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t total_bytes;
    uint64_t available_bytes;
    double read_bytes_per_second;
    double write_bytes_per_second;
    int capacity_valid;
    int io_valid;
    int device_count;
} MTDiskMetrics;

/* Capacity is statfs(/System/Volumes/Data), falling back to / only when the
 * Data mount path is absent. APFS space is shared with sibling volumes;
 * f_bavail is currently available space and does not add purgeable estimates.
 * IO is the interval average for physical, internal Solid State devices only.
 * The first sample, a device change, or a counter reset establishes a baseline
 * and has io_valid == 0. Successful idle intervals have valid zero rates.
 * Calls are process-wide and thread-safe. No identifiers are exported. */
MTDiskMetrics mt_disk_metrics_sample(void);

#ifdef __cplusplus
}
#endif

#endif
