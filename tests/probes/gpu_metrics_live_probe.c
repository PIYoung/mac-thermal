#include "GPUMetrics.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <time.h>

int main(void) {
    for (int index = 0; index < 3; ++index) {
        MTGPUMetrics metrics = mt_gpu_metrics_sample();
        assert(!metrics.utilization_valid || (isfinite(metrics.utilization_percent) &&
            metrics.utilization_percent >= 0 && metrics.utilization_percent <= 100));
        assert(metrics.model[127] == 0 && metrics.core_count >= 0);
        printf("GPU sample %d: valid=%d utilization=%.2f model=%s cores=%d\n",
            index + 1, metrics.utilization_valid, metrics.utilization_percent,
            metrics.model[0] ? metrics.model : "unavailable", metrics.core_count);
        if (index < 2) {
            struct timespec pause = {.tv_sec = 1, .tv_nsec = 0};
            nanosleep(&pause, NULL);
        }
    }
    mt_gpu_metrics_close();
    MTGPUMetrics reopened = mt_gpu_metrics_sample();
    assert(!reopened.utilization_valid || (isfinite(reopened.utilization_percent) &&
        reopened.utilization_percent >= 0 && reopened.utilization_percent <= 100));
    mt_gpu_metrics_close();
    puts("GPU live read-only sampling and teardown/reconnect passed (unsupported counters remain unavailable).");
    return 0;
}
