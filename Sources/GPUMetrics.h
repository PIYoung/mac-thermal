#ifndef MT_GPU_METRICS_H
#define MT_GPU_METRICS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double utilization_percent;
    int utilization_valid;
    char model[128];
    int core_count;
} MTGPUMetrics;

/* Apple Silicon's AGXAccelerator registry reports a device utilization
 * percentage on supported OS/driver combinations. Only that value is used;
 * renderer/tiler counters are not added or used as estimates. Missing,
 * nonnumeric, nonfinite and out-of-range fields remain unavailable, while a
 * measured zero is valid. Registry field availability is driver-dependent.
 * Model/core count are optional, independently validated metadata. The cached
 * service is read only, reconnects after disappearance, and requires no helper
 * or extra permission. Calls and teardown are process-wide and thread-safe. */
MTGPUMetrics mt_gpu_metrics_sample(void);
void mt_gpu_metrics_close(void);

#ifdef __cplusplus
}
#endif

#endif
