#include "GPUMetrics.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <pthread.h>
#include <string.h>
#include <time.h>

static pthread_mutex_t mt_gpu_mutex = PTHREAD_MUTEX_INITIALIZER;
static io_service_t mt_gpu_service = IO_OBJECT_NULL;
static MTGPUMetrics mt_gpu_metadata;
static double mt_gpu_retry_after;

static double mt_gpu_monotonic_seconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

static int mt_gpu_number(CFTypeRef value, double *result) {
    return value && CFGetTypeID(value) == CFNumberGetTypeID() &&
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, result) &&
        isfinite(*result);
}

/* Kept independent of registry access so malformed/unsupported driver values
 * can be regression-tested without a GPU or privileged process. */
static void mt_gpu_parse_utilization(CFTypeRef statistics, MTGPUMetrics *result) {
    if (!statistics || CFGetTypeID(statistics) != CFDictionaryGetTypeID()) return;
    double value = 0;
    if (mt_gpu_number(CFDictionaryGetValue((CFDictionaryRef)statistics,
            CFSTR("Device Utilization %")), &value) && value >= 0 && value <= 100) {
        result->utilization_percent = value;
        result->utilization_valid = 1;
    }
}

static void mt_gpu_parse_model(CFTypeRef value, MTGPUMetrics *result) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return;
    CFStringRef model = (CFStringRef)value;
    CFIndex length = CFStringGetLength(model);
    if (length <= 0 || length >= (CFIndex)sizeof(result->model)) return;
    int has_text = 0;
    for (CFIndex index = 0; index < length; ++index) {
        UniChar character = CFStringGetCharacterAtIndex(model, index);
        if (character < 32 || (character >= 127 && character <= 159)) return;
        if (character != ' ') has_text = 1;
    }
    if (has_text && !CFStringGetCString(model, result->model,
            sizeof(result->model), kCFStringEncodingUTF8)) {
        result->model[0] = '\0';
    }
}

static void mt_gpu_parse_cores(CFTypeRef value, MTGPUMetrics *result) {
    double cores = 0;
    if (mt_gpu_number(value, &cores) && cores >= 1 && cores <= 4096 &&
        trunc(cores) == cores) result->core_count = (int)cores;
}

static void mt_gpu_release_service(void) {
    if (mt_gpu_service) IOObjectRelease(mt_gpu_service);
    mt_gpu_service = IO_OBJECT_NULL;
}

static int mt_gpu_connect(double now) {
    if (mt_gpu_service) return 1;
    if (now < mt_gpu_retry_after) return 0;
    mt_gpu_retry_after = now + 30;
    CFMutableDictionaryRef matching = IOServiceMatching("AGXAccelerator");
    if (!matching) return 0;
    /* IOServiceGetMatchingService consumes matching, including on failure.
     * Apple Silicon has a single integrated AGX GPU; no unrelated accelerator
     * or a summed percentage across devices is substituted. */
    mt_gpu_service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!mt_gpu_service) return 0;
    memset(&mt_gpu_metadata, 0, sizeof(mt_gpu_metadata));
    CFTypeRef model = IORegistryEntryCreateCFProperty(mt_gpu_service,
        CFSTR("model"), kCFAllocatorDefault, 0);
    mt_gpu_parse_model(model, &mt_gpu_metadata);
    if (model) CFRelease(model);
    CFTypeRef cores = IORegistryEntryCreateCFProperty(mt_gpu_service,
        CFSTR("gpu-core-count"), kCFAllocatorDefault, 0);
    mt_gpu_parse_cores(cores, &mt_gpu_metadata);
    if (cores) CFRelease(cores);
    return 1;
}

MTGPUMetrics mt_gpu_metrics_sample(void) {
    pthread_mutex_lock(&mt_gpu_mutex);
    MTGPUMetrics result = {0};
    double now = mt_gpu_monotonic_seconds();
    if (mt_gpu_connect(now)) {
        result = mt_gpu_metadata;
        CFTypeRef statistics = IORegistryEntryCreateCFProperty(mt_gpu_service,
            CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
        mt_gpu_parse_utilization(statistics, &result);
        if (!statistics) {
            /* A removed service must not leave a retained dead connection.
             * Back off discovery on unsupported machines instead of scanning
             * the entire registry at every two-second metric refresh. */
            mt_gpu_release_service();
            mt_gpu_retry_after = now + 30;
        }
        if (statistics) CFRelease(statistics);
    }
    pthread_mutex_unlock(&mt_gpu_mutex);
    return result;
}

void mt_gpu_metrics_close(void) {
    pthread_mutex_lock(&mt_gpu_mutex);
    mt_gpu_release_service();
    memset(&mt_gpu_metadata, 0, sizeof(mt_gpu_metadata));
    mt_gpu_retry_after = 0;
    pthread_mutex_unlock(&mt_gpu_mutex);
}
