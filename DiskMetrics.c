#include "DiskMetrics.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOBlockStorageDevice.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <IOKit/storage/IOStorageDeviceCharacteristics.h>
#include <IOKit/storage/IOStorageProtocolCharacteristics.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/mount.h>
#include <time.h>

enum { MT_MAX_INTERNAL_SSDS = 64 };

typedef struct {
    uint64_t provider_id;
    uint64_t driver_id;
    uint64_t read_bytes;
    uint64_t write_bytes;
} MTPhysicalSSD;

typedef struct {
    MTPhysicalSSD devices[MT_MAX_INTERNAL_SSDS];
    size_t count;
    struct timespec time;
} MTDiskSnapshot;

static pthread_mutex_t mt_disk_mutex = PTHREAD_MUTEX_INITIALIZER;
static MTDiskSnapshot mt_disk_previous;
static int mt_disk_baseline;

static void mt_disk_capacity(MTDiskMetrics *result) {
    struct statfs stats;
    int status = statfs("/System/Volumes/Data", &stats);
    if (status != 0 && (errno == ENOENT || errno == ENOTDIR)) {
        status = statfs("/", &stats);
    }
    if (status != 0 || stats.f_bsize == 0 || stats.f_blocks == 0 ||
        stats.f_blocks > UINT64_MAX / stats.f_bsize ||
        stats.f_bavail > UINT64_MAX / stats.f_bsize) {
        return;
    }
    result->total_bytes = stats.f_blocks * stats.f_bsize;
    result->available_bytes = stats.f_bavail * stats.f_bsize;
    if (result->available_bytes > result->total_bytes) {
        result->available_bytes = result->total_bytes;
    }
    result->capacity_valid = 1;
}

/* Read only the needed characteristics, never persist names/serial numbers. */
static int mt_dictionary_string_equals(io_registry_entry_t entry,
                                       CFStringRef property,
                                       CFStringRef key, CFStringRef expected) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, property,
                                                     kCFAllocatorDefault, 0);
    int equals = 0;
    if (value && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
        CFTypeRef actual = CFDictionaryGetValue((CFDictionaryRef)value, key);
        equals = actual && CFEqual(actual, expected);
    }
    if (value) CFRelease(value);
    return equals;
}

static int mt_dictionary_uint64(CFDictionaryRef dictionary, CFStringRef key,
                                uint64_t *result) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    int64_t number = 0;
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID() ||
        !CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number) ||
        number < 0) {
        return 0;
    }
    *result = (uint64_t)number;
    return 1;
}

static int mt_device_compare(const void *left, const void *right) {
    const MTPhysicalSSD *a = left;
    const MTPhysicalSSD *b = right;
    return (a->provider_id > b->provider_id) -
           (a->provider_id < b->provider_id);
}

static int mt_read_disks(MTDiskSnapshot *snapshot) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    CFMutableDictionaryRef matching = IOServiceMatching(kIOBlockStorageDriverClass);
    if (!matching || IOServiceGetMatchingServices(kIOMainPortDefault, matching,
                                                 &iterator) != KERN_SUCCESS) {
        return 0;
    }
    int valid = 1;
    io_registry_entry_t driver;
    while ((driver = IOIteratorNext(iterator))) {
        io_registry_entry_t provider = IO_OBJECT_NULL;
        if (IORegistryEntryGetParentEntry(driver, kIOServicePlane, &provider) !=
            KERN_SUCCESS) {
            valid = 0;
            IOObjectRelease(driver);
            break;
        }
        /* The physical block storage device is the immediate provider. APFS
         * container/volume counters and synthesized media are never summed. */
        int internal_ssd = IOObjectConformsTo(provider, kIOBlockStorageDeviceClass) &&
            mt_dictionary_string_equals(provider,
                CFSTR(kIOPropertyProtocolCharacteristicsKey),
                CFSTR(kIOPropertyPhysicalInterconnectLocationKey),
                CFSTR(kIOPropertyInternalKey)) &&
            mt_dictionary_string_equals(provider,
                CFSTR(kIOPropertyDeviceCharacteristicsKey),
                CFSTR(kIOPropertyMediumTypeKey),
                CFSTR(kIOPropertyMediumTypeSolidStateKey));
        if (internal_ssd) {
            MTPhysicalSSD device = {0};
            valid = IORegistryEntryGetRegistryEntryID(provider, &device.provider_id) ==
                        KERN_SUCCESS &&
                    IORegistryEntryGetRegistryEntryID(driver, &device.driver_id) ==
                        KERN_SUCCESS;
            int duplicate = 0;
            for (size_t index = 0; valid && index < snapshot->count; ++index) {
                if (snapshot->devices[index].provider_id == device.provider_id) {
                    duplicate = 1;
                    break;
                }
            }
            if (valid && !duplicate) {
                CFTypeRef statistics = IORegistryEntryCreateCFProperty(driver,
                    CFSTR(kIOBlockStorageDriverStatisticsKey),
                    kCFAllocatorDefault, 0);
                valid = statistics &&
                    CFGetTypeID(statistics) == CFDictionaryGetTypeID() &&
                    mt_dictionary_uint64((CFDictionaryRef)statistics,
                        CFSTR(kIOBlockStorageDriverStatisticsBytesReadKey),
                        &device.read_bytes) &&
                    mt_dictionary_uint64((CFDictionaryRef)statistics,
                        CFSTR(kIOBlockStorageDriverStatisticsBytesWrittenKey),
                        &device.write_bytes) &&
                    snapshot->count < MT_MAX_INTERNAL_SSDS;
                if (statistics) CFRelease(statistics);
                if (valid) snapshot->devices[snapshot->count++] = device;
            }
        }
        IOObjectRelease(provider);
        IOObjectRelease(driver);
        if (!valid) break;
    }
    if (!IOIteratorIsValid(iterator)) valid = 0;
    IOObjectRelease(iterator);
    if (!valid || snapshot->count == 0 ||
        clock_gettime(CLOCK_MONOTONIC, &snapshot->time) != 0) {
        return 0;
    }
    qsort(snapshot->devices, snapshot->count, sizeof(snapshot->devices[0]),
          mt_device_compare);
    return 1;
}

MTDiskMetrics mt_disk_metrics_sample(void) {
    MTDiskMetrics result = {0};
    pthread_mutex_lock(&mt_disk_mutex);
    mt_disk_capacity(&result);
    MTDiskSnapshot current = {0};
    if (!mt_read_disks(&current)) {
        mt_disk_baseline = 0;
        pthread_mutex_unlock(&mt_disk_mutex);
        return result;
    }
    result.device_count = (int)current.count;
    double elapsed = (double)(current.time.tv_sec - mt_disk_previous.time.tv_sec) +
        (double)(current.time.tv_nsec - mt_disk_previous.time.tv_nsec) / 1e9;
    int valid = mt_disk_baseline && current.count == mt_disk_previous.count &&
                elapsed > 0 && isfinite(elapsed);
    double read_delta = 0;
    double write_delta = 0;
    for (size_t index = 0; valid && index < current.count; ++index) {
        const MTPhysicalSSD *now = &current.devices[index];
        const MTPhysicalSSD *before = &mt_disk_previous.devices[index];
        valid = now->provider_id == before->provider_id &&
                now->driver_id == before->driver_id &&
                now->read_bytes >= before->read_bytes &&
                now->write_bytes >= before->write_bytes;
        if (valid) {
            read_delta += (double)(now->read_bytes - before->read_bytes);
            write_delta += (double)(now->write_bytes - before->write_bytes);
        }
    }
    if (valid) {
        result.read_bytes_per_second = read_delta / elapsed;
        result.write_bytes_per_second = write_delta / elapsed;
        result.io_valid = isfinite(result.read_bytes_per_second) &&
                          isfinite(result.write_bytes_per_second);
    }
    mt_disk_previous = current;
    mt_disk_baseline = 1;
    pthread_mutex_unlock(&mt_disk_mutex);
    return result;
}
