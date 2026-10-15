#include "SystemMetrics.h"

#include <stdio.h>
#include <time.h>

int main(void) {
    const struct timespec interval = {.tv_sec = 1, .tv_nsec = 0};
    for (int i = 0; i < 4; ++i) {
        MTSystemMetrics value = mt_system_metrics_sample();
        printf("cpu_valid=%d cpu=%.2f%% net_valid=%d interfaces=%d "
               "download=%.2f B/s upload=%.2f B/s\n",
               value.cpu_valid, value.cpu_usage_percent,
               value.network_valid, value.interface_count,
               value.download_bytes_per_second, value.upload_bytes_per_second);
        if (i < 3) {
            nanosleep(&interval, NULL);
        }
    }
    return 0;
}
