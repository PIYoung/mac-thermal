#ifndef MT_SYSTEM_METRICS_H
#define MT_SYSTEM_METRICS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double cpu_usage_percent;
    double upload_bytes_per_second;
    double download_bytes_per_second;
    int cpu_valid;
    int network_valid;
    int interface_count;
} MTSystemMetrics;

/* Process-wide sampler. Calls may be made from any thread. The first successful
 * sample establishes a baseline; subsequent samples contain interval averages. */
MTSystemMetrics mt_system_metrics_sample(void);

#ifdef __cplusplus
}
#endif

#endif
