/* Synthetic driver fixtures: no live registry or sensor reads. */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static int fixture_connects, fixture_releases, fixture_metadata_reads;
static int fixture_available = 1, fixture_disappeared;
static time_t fixture_seconds = 100;
static double fixture_utilization = 42;

static io_service_t fixture_matching(mach_port_t port, CFDictionaryRef matching) {
    assert(port == kIOMainPortDefault && matching);
    CFRelease(matching);
    ++fixture_connects;
    return fixture_available ? 42 : IO_OBJECT_NULL;
}

static CFTypeRef fixture_property(io_registry_entry_t service, CFStringRef key,
                                  CFAllocatorRef allocator, IOOptionBits options) {
    assert(service == 42 && allocator == kCFAllocatorDefault && options == 0);
    if (CFEqual(key, CFSTR("model"))) {
        ++fixture_metadata_reads;
        return CFRetain(CFSTR("Apple Fixture GPU"));
    }
    if (CFEqual(key, CFSTR("gpu-core-count"))) {
        ++fixture_metadata_reads;
        int cores = 20;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &cores);
    }
    assert(CFEqual(key, CFSTR("PerformanceStatistics")));
    if (fixture_disappeared) return NULL;
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault,
        kCFNumberDoubleType, &fixture_utilization);
    const void *keys[] = {CFSTR("Device Utilization %")};
    const void *values[] = {number};
    CFDictionaryRef result = CFDictionaryCreate(kCFAllocatorDefault, keys, values,
        1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    return result;
}

static kern_return_t fixture_release(io_object_t object) {
    assert(object == 42);
    ++fixture_releases;
    return KERN_SUCCESS;
}

static int fixture_clock(clockid_t clock, struct timespec *result) {
    assert(clock == CLOCK_MONOTONIC);
    result->tv_sec = fixture_seconds;
    result->tv_nsec = 0;
    return 0;
}

#define IOServiceGetMatchingService fixture_matching
#define IORegistryEntryCreateCFProperty fixture_property
#define IOObjectRelease fixture_release
#define clock_gettime fixture_clock
#include "../../Sources/GPUMetrics.c"

static MTGPUMetrics parse_value(CFTypeRef value, CFStringRef key) {
    const void *keys[] = {key};
    const void *values[] = {value};
    CFDictionaryRef statistics = CFDictionaryCreate(kCFAllocatorDefault,
        keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    MTGPUMetrics result = {0};
    mt_gpu_parse_utilization(statistics, &result);
    CFRelease(statistics);
    return result;
}

static void check_number(double value, int valid) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault,
        kCFNumberDoubleType, &value);
    MTGPUMetrics result = parse_value(number, CFSTR("Device Utilization %"));
    assert(result.utilization_valid == valid);
    if (valid) assert(result.utilization_percent == value);
    CFRelease(number);
}

static void check_parser(void) {
    check_number(0, 1);
    check_number(100, 1);
    check_number(42.75, 1);
    check_number(-1, 0);
    check_number(100.01, 0);
    check_number(INFINITY, 0);
    check_number(-INFINITY, 0);
    check_number(NAN, 0);
    assert(!parse_value(CFSTR("42"), CFSTR("Device Utilization %")).utilization_valid);
    assert(!parse_value(kCFBooleanTrue, CFSTR("Device Utilization %")).utilization_valid);
    double renderer_value = 40;
    CFNumberRef renderer = CFNumberCreate(kCFAllocatorDefault,
        kCFNumberDoubleType, &renderer_value);
    /* Related counters can be present while overall device usage is unknown. */
    assert(!parse_value(renderer, CFSTR("Renderer Utilization %")).utilization_valid);
    assert(!parse_value(renderer, CFSTR("Tiler Utilization %")).utilization_valid);
    CFRelease(renderer);
    MTGPUMetrics missing = {0};
    mt_gpu_parse_utilization(NULL, &missing);
    mt_gpu_parse_utilization(CFSTR("unsupported"), &missing);
    assert(!missing.utilization_valid);

    MTGPUMetrics model = {0};
    mt_gpu_parse_model(CFSTR("Apple M4 Pro"), &model);
    assert(strcmp(model.model, "Apple M4 Pro") == 0 && model.model[127] == 0);
    memset(&model, 0, sizeof(model));
    mt_gpu_parse_model(CFSTR("bad\nmodel"), &model);
    assert(!model.model[0]);
    mt_gpu_parse_model(CFSTR("   "), &model);
    assert(!model.model[0]);
    mt_gpu_parse_model(kCFBooleanTrue, &model);
    assert(!model.model[0]);
    char long_model[180];
    memset(long_model, 'x', sizeof(long_model) - 1);
    long_model[sizeof(long_model) - 1] = 0;
    CFStringRef long_string = CFStringCreateWithCString(kCFAllocatorDefault,
        long_model, kCFStringEncodingUTF8);
    mt_gpu_parse_model(long_string, &model);
    assert(!model.model[0]);
    CFRelease(long_string);

    const double core_values[] = {20, 0, -1, 20.5, INFINITY, NAN, 4097};
    for (size_t index = 0; index < sizeof(core_values) / sizeof(core_values[0]); ++index) {
        MTGPUMetrics cores = {0};
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault,
            kCFNumberDoubleType, &core_values[index]);
        mt_gpu_parse_cores(number, &cores);
        assert(cores.core_count == (index == 0 ? 20 : 0));
        CFRelease(number);
    }
}

static void check_lifecycle(void) {
    MTGPUMetrics first = mt_gpu_metrics_sample();
    assert(first.utilization_valid && first.utilization_percent == 42);
    assert(first.core_count == 20 && strcmp(first.model, "Apple Fixture GPU") == 0);
    assert(fixture_connects == 1 && fixture_metadata_reads == 2);
    fixture_utilization = 0;
    MTGPUMetrics idle = mt_gpu_metrics_sample();
    assert(idle.utilization_valid && idle.utilization_percent == 0);
    assert(fixture_connects == 1 && fixture_metadata_reads == 2);

    fixture_disappeared = 1;
    MTGPUMetrics removed = mt_gpu_metrics_sample();
    assert(!removed.utilization_valid && fixture_releases == 1);
    fixture_disappeared = 0;
    fixture_seconds += 29;
    assert(!mt_gpu_metrics_sample().utilization_valid && fixture_connects == 1);
    ++fixture_seconds;
    assert(mt_gpu_metrics_sample().utilization_valid && fixture_connects == 2);
    mt_gpu_metrics_close();
    assert(fixture_releases == 2);

    fixture_available = 0;
    assert(!mt_gpu_metrics_sample().utilization_valid && fixture_connects == 3);
    fixture_available = 1;
    assert(!mt_gpu_metrics_sample().utilization_valid && fixture_connects == 3);
    fixture_seconds += 30;
    assert(mt_gpu_metrics_sample().utilization_valid && fixture_connects == 4);
    mt_gpu_metrics_close();
    mt_gpu_metrics_close();
    assert(fixture_releases == 3);
    assert(mt_gpu_metrics_sample().utilization_valid && fixture_connects == 5);
    mt_gpu_metrics_close();
    assert(fixture_releases == 4);
}

int main(void) {
    check_parser();
    check_lifecycle();
    puts("GPU fixtures passed: valid idle/full/fractional usage; unavailable missing,"
         " wrong-type, nonfinite and out-of-range values; no renderer/tiler fallback;"
         " metadata validation; cached connection, retry backoff, disappearance recovery"
         " and idempotent teardown.");
    return 0;
}
