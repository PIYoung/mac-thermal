/* SMC protocol and sensor keys informed by exelban/Stats (MIT).
 * Copyright (c) 2019 Serhiy Mytrovtsiy (Stats repository license).
 * Referenced source files: Copyright (c) 2020, 2021 Serhiy Mytrovtsiy.
 * All rights reserved; distributed under the repository MIT License.
 * See THIRD_PARTY_NOTICES.txt for reference URLs and the full MIT notice. */
#include "ThermalSensors.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpu_limit, gpu_limit, memory_limit; } SMCPowerLimit;
typedef struct { uint32_t size, type; uint8_t attributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPowerLimit power_limit;
    SMCKeyInfo key_info;
    uint8_t result, status, command;
    uint32_t data;
    uint8_t bytes[32];
} SMCData;

_Static_assert(sizeof(SMCData) == 80, "Unexpected SMC ABI");
static io_connect_t connection = IO_OBJECT_NULL;
static bool smc_attempted;

static uint32_t fourcc(const char *key) {
    return ((uint32_t)(uint8_t)key[0] << 24) | ((uint32_t)(uint8_t)key[1] << 16) |
           ((uint32_t)(uint8_t)key[2] << 8) | (uint32_t)(uint8_t)key[3];
}

static bool smc_open(void) {
    if (connection) return true;
    if (smc_attempted) return false;
    smc_attempted = true;
    const char *classes[] = {"AppleSMC", "AppleSMCKeysEndpoint"};
    for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); ++i) {
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(classes[i]));
        if (!service) continue;
        kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
        IOObjectRelease(service);
        if (result == KERN_SUCCESS && connection) return true;
        connection = IO_OBJECT_NULL;
    }
    return false;
}

static bool smc_call(SMCData *input, SMCData *output) {
    size_t size = sizeof(*output);
    memset(output, 0, size);
    kern_return_t result = IOConnectCallStructMethod(connection, 2, input, sizeof(*input), output, &size);
    return result == KERN_SUCCESS && size == sizeof(*output) && output->result == 0;
}

static bool smc_read(const char *key, double *temperature) {
    if (!smc_open()) return false;
    SMCData input = {0}, output = {0};
    input.key = fourcc(key);
    input.command = 9;
    if (!smc_call(&input, &output) || !output.key_info.size || output.key_info.size > 32) return false;
    uint32_t type = output.key_info.type;
    input.key_info.size = output.key_info.size;
    input.command = 5;
    if (!smc_call(&input, &output)) return false;
    double value = 0;
    if (type == fourcc("flt ") && input.key_info.size == 4) {
        float raw;
        memcpy(&raw, output.bytes, sizeof(raw));
        value = raw;
    } else if (type == fourcc("sp78") && input.key_info.size == 2) {
        int16_t raw = (int16_t)(((uint16_t)output.bytes[0] << 8) | output.bytes[1]);
        value = (double)raw / 256.0;
    } else if (type == fourcc("fpe2") && input.key_info.size == 2) {
        uint16_t raw = ((uint16_t)output.bytes[0] << 8) | output.bytes[1];
        value = (double)raw / 4.0;
    } else return false;
    if (!isfinite(value) || value < 1.0 || value > 130.0) return false;
    *temperature = value;
    return true;
}

// Only CPU-labelled keys are used. PMU tdie/tdev are not CPU sensors.
// Apple Silicon families use different core sensor keys; unavailable keys are skipped.
static const char *cpu_keys[] = {
    "Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D",
    "Tp0V", "Tp0Y", "Tp0b", "Tp0e"
};
static const char *ssd_keys[] = {"TH0x"};

typedef CFTypeRef (*CreateClient)(CFAllocatorRef);
typedef void (*SetMatching)(CFTypeRef, CFDictionaryRef);
typedef CFArrayRef (*CopyServices)(CFTypeRef);
typedef CFTypeRef (*CopyProperty)(CFTypeRef, CFStringRef);
typedef CFTypeRef (*CopyEvent)(CFTypeRef, int64_t, int32_t, int64_t);
typedef double (*EventFloat)(CFTypeRef, int32_t);
static CFTypeRef hid_client;
static void *hid_library;
static bool hid_attempted;
static CopyServices copy_services;
static CopyProperty copy_property;
static CopyEvent copy_event;
static EventFloat event_float;

static void hid_open(void) {
    if (hid_attempted) return;
    hid_attempted = true;
    void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    if (!library) return;
    hid_library = library;
    CreateClient create_client = (CreateClient)dlsym(library, "IOHIDEventSystemClientCreate");
    SetMatching set_matching = (SetMatching)dlsym(library, "IOHIDEventSystemClientSetMatching");
    copy_services = (CopyServices)dlsym(library, "IOHIDEventSystemClientCopyServices");
    copy_property = (CopyProperty)dlsym(library, "IOHIDServiceClientCopyProperty");
    copy_event = (CopyEvent)dlsym(library, "IOHIDServiceClientCopyEvent");
    event_float = (EventFloat)dlsym(library, "IOHIDEventGetFloatValue");
    if (!create_client || !set_matching || !copy_services || !copy_property || !copy_event || !event_float) return;
    hid_client = create_client(kCFAllocatorDefault);
    if (!hid_client) return;
    int page = 0xff00, usage = 5;
    CFNumberRef page_ref = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usage_ref = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {page_ref, usage_ref};
    CFDictionaryRef criteria = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    set_matching(hid_client, criteria);
    CFRelease(criteria);
    CFRelease(page_ref);
    CFRelease(usage_ref);
}

static void add_reading(double value, double *max, int *count) {
    if (!isfinite(value) || value < 1 || value > 130) return;
    if (*count == 0 || value > *max) *max = value;
    ++*count;
}

MTThermalReading mt_thermal_read(void) {
    MTThermalReading reading = {0};
    for (size_t i = 0; i < sizeof(cpu_keys) / sizeof(cpu_keys[0]); ++i) {
        double value;
        if (smc_read(cpu_keys[i], &value)) add_reading(value, &reading.cpu_celsius, &reading.cpu_sensor_count);
    }
    if (reading.cpu_sensor_count) snprintf(reading.cpu_source, sizeof(reading.cpu_source), "SMC CPU sensors (max)");
    const bool smc_cpu_available = reading.cpu_sensor_count > 0;
    hid_open();
    if (hid_client) {
        CFArrayRef services = copy_services(hid_client);
        if (services) {
            for (CFIndex i = 0; i < CFArrayGetCount(services); ++i) {
                CFTypeRef service = CFArrayGetValueAtIndex(services, i);
                CFTypeRef product = copy_property(service, CFSTR("Product"));
                if (!product) continue;
                char name[256] = {0};
                bool valid = CFGetTypeID(product) == CFStringGetTypeID() && CFStringGetCString(product, name, sizeof(name), kCFStringEncodingUTF8);
                CFRelease(product);
                bool is_cpu = valid && (strncmp(name, "pACC MTR Temp Sensor", 19) == 0 || strncmp(name, "eACC MTR Temp Sensor", 19) == 0);
                bool is_ssd = valid && strncmp(name, "NAND CH", 7) == 0 && strstr(name, "temp");
                /* SMC is preferred, so these CPU events would be discarded.
                 * Continue reading every HID CPU sensor when SMC is absent. */
                if ((!is_cpu || smc_cpu_available) && !is_ssd) continue;
                CFTypeRef event = copy_event(service, 15, 0, 0);
                if (!event) continue;
                double value = event_float(event, 15 << 16);
                CFRelease(event);
                if (is_cpu && !reading.cpu_sensor_count) {
                    add_reading(value, &reading.cpu_celsius, &reading.cpu_sensor_count);
                    snprintf(reading.cpu_source, sizeof(reading.cpu_source), "HID CPU sensors (max)");
                } else if (is_cpu && strncmp(reading.cpu_source, "HID", 3) == 0) {
                    add_reading(value, &reading.cpu_celsius, &reading.cpu_sensor_count);
                }
                if (is_ssd) {
                    add_reading(value, &reading.ssd_celsius, &reading.ssd_sensor_count);
                    snprintf(reading.ssd_source, sizeof(reading.ssd_source), "NAND temperature sensors (max)");
                }
            }
            CFRelease(services);
        }
    }
    if (!reading.ssd_sensor_count) {
        for (size_t i = 0; i < sizeof(ssd_keys) / sizeof(ssd_keys[0]); ++i) {
            double value;
            if (smc_read(ssd_keys[i], &value)) add_reading(value, &reading.ssd_celsius, &reading.ssd_sensor_count);
        }
        if (reading.ssd_sensor_count) snprintf(reading.ssd_source, sizeof(reading.ssd_source), "SMC storage sensors (max)");
    }
    return reading;
}

void mt_thermal_close(void) {
    if (connection) IOServiceClose(connection);
    connection = IO_OBJECT_NULL;
    smc_attempted = false;
    if (hid_client) CFRelease(hid_client);
    hid_client = NULL;
    hid_attempted = false;
    if (hid_library) dlclose(hid_library);
    hid_library = NULL;
}
