/* Owned synthetic sensor fixtures. Never touches actual sensor services. */
#include <assert.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <sys/sysctl.h>
#include <stdio.h>
static kern_return_t fixture_call(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);
static int fixture_sysctl(const char *, void *, size_t *, const void *, size_t);
#define IOConnectCallStructMethod fixture_call
#define sysctlbyname fixture_sysctl
#include "../../Sources/ThermalSensors.c"
static const char *brand = "Apple M4 Pro";
static int gpu_key_calls, platform_calls;
static int gpu_present = 1, memory_present = 1;
static CFArrayRef services;
static int fixture_sysctl(const char *name, void *output, size_t *size, const void *write, size_t write_size) {
    assert(strcmp(name, "machdep.cpu.brand_string") == 0 && !write && write_size == 0);
    assert(*size >= strlen(brand) + 1); strcpy(output, brand); *size = strlen(brand) + 1; ++platform_calls; return 0;
}
static kern_return_t fixture_call(mach_port_t port, uint32_t selector, const void *raw,
                                  size_t size, void *result, size_t *result_size) {
    assert(port == 1 && selector == 2 && size == sizeof(SMCData) && *result_size == size);
    const SMCData *input = raw; SMCData *output = result;
    assert(input->command == 9 || input->command == 5);
    const char *gpu[] = {"Tg1U","Tg1k","Tg0K","Tg0L","Tg0d","Tg0e","Tg0j","Tg0k","Tg0G","Tg0H"};
    const char *memory[] = {"Tm0p","Tm1p","Tm2p"};
    float value = 0; bool found = false;
    for(unsigned i=0;i<sizeof(gpu)/sizeof(*gpu);i++) if(input->key == fourcc(gpu[i])) {
        ++gpu_key_calls;
        if(gpu_present) { value = i == 7 ? 78 : 70; found = true; }
    }
    for(unsigned i=0;i<sizeof(memory)/sizeof(*memory);i++) if(input->key == fourcc(memory[i])) {
        if(memory_present && i < 2) { value = i == 0 ? 69 : 67; found = true; }
    }
    if(!found) { output->result = 1; return KERN_SUCCESS; }
    if(input->command == 9) { output->key_info.size = 4; output->key_info.type = fourcc("flt "); }
    else memcpy(output->bytes,&value,4);
    return KERN_SUCCESS;
}
static CFArrayRef fixture_services(CFTypeRef client) { assert(client == hid_client); return CFRetain(services); }
static CFTypeRef fixture_property(CFTypeRef service, CFStringRef key) {
    CFTypeRef v=CFDictionaryGetValue(service,key);return v ? CFRetain(v) : NULL;
}
static CFTypeRef fixture_event(CFTypeRef service, int64_t type, int32_t zero, int64_t options) {
    assert(type == 15 && !zero && !options);return CFRetain(service);
}
static double fixture_value(CFTypeRef event,int32_t field) {
    assert(field == 15<<16);double v=0;
    CFNumberGetValue(CFDictionaryGetValue(event,CFSTR("Value")),kCFNumberDoubleType,&v);return v;
}
static void fixture_hid(void) {
    CFMutableArrayRef array=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    const CFStringRef names[]={CFSTR("GPU MTR Temp Sensor 0"),CFSTR("GPU MTR Temp Sensor 1"),CFSTR("PMU tdie1"),CFSTR("GPU MTR Temp Sensor 2")};
    double values[]={64,66,110,NAN};
    for(int i=0;i<4;i++) {
        CFMutableDictionaryRef d=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        CFNumberRef v=CFNumberCreate(NULL,kCFNumberDoubleType,&values[i]);
        CFDictionarySetValue(d,CFSTR("Product"),names[i]);CFDictionarySetValue(d,CFSTR("Value"),v);
        CFArrayAppendValue(array,d);CFRelease(d);CFRelease(v);
    }
    services=array;hid_client=CFSTR("fixture");copy_services=fixture_services;
    copy_property=fixture_property;copy_event=fixture_event;event_float=fixture_value;
}
int main(void) {
    connection=1;smc_attempted=true;hid_attempted=true;
    MTThermalReading r=mt_thermal_read();
    assert(r.gpu_sensor_count==8 && r.gpu_celsius==78);
    assert(r.memory_proximity_sensor_count==2 && r.memory_proximity_celsius==69);
    assert(r.cpu_sensor_count==0 && r.ssd_sensor_count==0 && platform_calls==1);
    r=mt_thermal_read();assert(platform_calls==1);
    gpu_present=memory_present=0;r=mt_thermal_read();
    assert(r.gpu_sensor_count==0 && r.memory_proximity_sensor_count==0);
    gpu_present=memory_present=1;brand="Apple M4";m4_kind=-1;r=mt_thermal_read();
    assert(r.gpu_sensor_count==8 && r.memory_proximity_sensor_count==2);
    brand="Apple M4 Max";m4_kind=-1;r=mt_thermal_read();assert(r.gpu_sensor_count==8);
    const char *other[]={"Apple M3 Pro","Apple M5","Unknown","Apple M4 Pro Fake"};
    for(unsigned i=0;i<sizeof(other)/sizeof(*other);i++) {
        brand=other[i];m4_kind=-1;gpu_key_calls=0;r=mt_thermal_read();
        assert(r.gpu_sensor_count==0 && r.memory_proximity_sensor_count==0 && gpu_key_calls==0);
    }
    fixture_hid();r=mt_thermal_read();
    assert(r.gpu_sensor_count==2 && r.gpu_celsius==66 && r.memory_proximity_sensor_count==0);
    brand="Apple M4 Pro";m4_kind=-1;r=mt_thermal_read();
    assert(r.gpu_sensor_count==8 && r.gpu_celsius==78); /* Prefer SMC; no duplicated HID values. */
    connection=0;hid_client=NULL;CFRelease(services);
    puts("PASS component temperatures: M4/Pro/Max gated keys, GPU max, memory proximity max, unavailable values, cached platform, explicit HID fallback, PMU exclusion, read commands only");
}
