/* Synthetic SMC/HID fixture: does not access actual sensors or applications. */
#include <assert.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
static kern_return_t fixture_smc_call(mach_port_t connection, uint32_t selector,
                                     const void *input, size_t input_size,
                                     void *output, size_t *output_size);
#define IOConnectCallStructMethod fixture_smc_call
#include "../../Sources/ThermalSensors.c"

static int smc_cpu_valid, smc_ssd_valid, hid_cpu_calls, hid_ssd_calls;
static CFArrayRef fixture_services;
static kern_return_t fixture_smc_call(mach_port_t port, uint32_t selector,
                                     const void *raw_input, size_t input_size,
                                     void *raw_output, size_t *output_size) {
    assert(port == 1 && selector == 2 && input_size == sizeof(SMCData));
    assert(*output_size == sizeof(SMCData));
    const SMCData *input = raw_input;
    SMCData *output = raw_output;
    int ssd = input->key == fourcc("TH0x");
    if ((ssd && !smc_ssd_valid) || (!ssd && !smc_cpu_valid)) {
        output->result = 1;
        return KERN_SUCCESS;
    }
    if (input->command == 9) {
        output->key_info.size = 4;
        output->key_info.type = fourcc("flt ");
    } else {
        assert(input->command == 5);
        float temperature = ssd ? 55 : 42;
        memcpy(output->bytes, &temperature, sizeof(temperature));
    }
    return KERN_SUCCESS;
}
static CFArrayRef fixture_copy_services(CFTypeRef client) {
    assert(client == hid_client);
    return CFRetain(fixture_services);
}
static CFTypeRef fixture_property(CFTypeRef service, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(service, key);
    return value ? CFRetain(value) : NULL;
}
static CFTypeRef fixture_event(CFTypeRef service, int64_t type, int32_t zero,
                                int64_t options) {
    assert(type == 15 && zero == 0 && options == 0);
    CFStringRef name = CFDictionaryGetValue(service, CFSTR("Product"));
    if (CFStringHasPrefix(name, CFSTR("NAND"))) ++hid_ssd_calls;
    else ++hid_cpu_calls;
    return CFRetain(service);
}
static double fixture_temperature(CFTypeRef event, int32_t field) {
    assert(field == 15 << 16);
    double temperature = 0;
    CFNumberGetValue(CFDictionaryGetValue(event, CFSTR("Temperature")),
                     kCFNumberDoubleType, &temperature);
    return temperature;
}
static void prepare(int has_ssd, double first_cpu) {
    if (fixture_services) CFRelease(fixture_services);
    const CFStringRef names[] = {CFSTR("pACC MTR Temp Sensor 0"),
        CFSTR("eACC MTR Temp Sensor 1"), CFSTR("NAND CH0 temp"),
        CFSTR("NAND CH1 temp"), CFSTR("Unrelated sensor")};
    const double temperatures[] = {first_cpu, 68, 47, 53, 99};
    CFMutableArrayRef services = CFArrayCreateMutable(NULL, 0,
                                                     &kCFTypeArrayCallBacks);
    for (int index = 0; index < 5; ++index) {
        if (!has_ssd && (index == 2 || index == 3)) continue;
        CFMutableDictionaryRef service = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFNumberRef temperature = CFNumberCreate(NULL, kCFNumberDoubleType,
                                                 &temperatures[index]);
        CFDictionarySetValue(service, CFSTR("Product"), names[index]);
        CFDictionarySetValue(service, CFSTR("Temperature"), temperature);
        CFArrayAppendValue(services, service);
        CFRelease(temperature); CFRelease(service);
    }
    fixture_services = services;
    hid_cpu_calls = hid_ssd_calls = 0;
    connection = 1; smc_attempted = true; hid_attempted = true;
    hid_client = CFSTR("fixture client");
    copy_services = fixture_copy_services; copy_property = fixture_property;
    copy_event = fixture_event; event_float = fixture_temperature;
}
static void report(const char *scenario, MTThermalReading reading) {
    printf("scenario=%s cpu=%.1f count=%d source=%s ssd=%.1f count=%d "
           "source=%s hid_cpu_events=%d hid_ssd_events=%d\n", scenario,
           reading.cpu_celsius, reading.cpu_sensor_count, reading.cpu_source,
           reading.ssd_celsius, reading.ssd_sensor_count, reading.ssd_source,
           hid_cpu_calls, hid_ssd_calls);
}
int main(void) {
    smc_cpu_valid = smc_ssd_valid = 1;
    prepare(1, 60);
    MTThermalReading preferred = mt_thermal_read();
    assert(preferred.cpu_celsius == 42 && preferred.cpu_sensor_count == 12);
    assert(preferred.ssd_celsius == 53 && preferred.ssd_sensor_count == 2);
    assert(strcmp(preferred.cpu_source, "SMC CPU sensors (max)") == 0);
    assert(strcmp(preferred.ssd_source, "NAND temperature sensors (max)") == 0);
    assert(hid_cpu_calls == 0 && hid_ssd_calls == 2);
    report("smc_cpu", preferred);
    smc_cpu_valid = 0;
    prepare(1, 60);
    MTThermalReading fallback = mt_thermal_read();
    assert(fallback.cpu_celsius == 68 && fallback.cpu_sensor_count == 2);
    assert(fallback.ssd_celsius == 53 && fallback.ssd_sensor_count == 2);
    assert(strcmp(fallback.cpu_source, "HID CPU sensors (max)") == 0);
    assert(strcmp(fallback.ssd_source, "NAND temperature sensors (max)") == 0);
    assert(hid_cpu_calls == 2 && hid_ssd_calls == 2);
    report("hid_fallback", fallback);
    prepare(1, 0);
    MTThermalReading invalid = mt_thermal_read();
    assert(invalid.cpu_celsius == 68 && invalid.cpu_sensor_count == 1);
    assert(strcmp(invalid.cpu_source, "HID CPU sensors (max)") == 0);
    assert(invalid.ssd_celsius == 53 && invalid.ssd_sensor_count == 2);
    assert(hid_cpu_calls == 2 && hid_ssd_calls == 2);
    report("invalid_first_hid", invalid);
    prepare(0, 60);
    MTThermalReading storage = mt_thermal_read();
    assert(storage.cpu_celsius == 68 && storage.cpu_sensor_count == 2);
    assert(storage.ssd_celsius == 55 && storage.ssd_sensor_count == 1);
    assert(strcmp(storage.cpu_source, "HID CPU sensors (max)") == 0);
    assert(strcmp(storage.ssd_source, "SMC storage sensors (max)") == 0);
    assert(hid_cpu_calls == 2 && hid_ssd_calls == 0);
    report("smc_ssd_fallback", storage);
    CFRelease(fixture_services);
    puts("Synthetic thermal fallback passed; actual sensors and system settings untouched.");
    return 0;
}
