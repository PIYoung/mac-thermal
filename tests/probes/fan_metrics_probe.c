/* Synthetic read-only SMC responses. No actual sensors or fan controls. */
#include <assert.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
static kern_return_t fixture_call(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);
#define IOConnectCallStructMethod fixture_call
#include "../../Sources/ThermalSensors.c"
static double count_value = 2, speeds[MT_MAX_FANS] = {1800, 2100};
static uint32_t types[MT_MAX_FANS];
static unsigned missing;
static bool missing_count;
static int calls;
static kern_return_t fixture_call(mach_port_t port, uint32_t selector, const void *raw,
                                  size_t size, void *result, size_t *result_size) {
    assert(port == 1 && selector == 2 && size == sizeof(SMCData) && *result_size == size);
    const SMCData *input = raw;
    SMCData *output = result;
    assert(input->command == 9 || input->command == 5); /* Never writes. */
    ++calls;
    bool is_count = input->key == fourcc("FNum");
    int index = (int)((input->key >> 16) & 255) - '0';
    assert(is_count || (index >= 0 && index < MT_MAX_FANS &&
           (input->key & 0xff00ffffu) == (fourcc("F0Ac") & 0xff00ffffu)));
    if ((is_count && missing_count) || (!is_count && (missing & (1u << index)))) {
        output->result = 1; return KERN_SUCCESS;
    }
    uint32_t type = is_count ? fourcc("flt ") : types[index];
    uint32_t length = type == fourcc("flt ") ? 4 : type == fourcc("ui8 ") ? 1 : 2;
    if (input->command == 9) {
        output->key_info.size = length; output->key_info.type = type;
    } else {
        double value = is_count ? count_value : speeds[index];
        if (type == fourcc("flt ")) { float number = (float)value; memcpy(output->bytes, &number, 4); }
        else if (type == fourcc("ui8 ")) output->bytes[0] = (uint8_t)value;
        else if (type == fourcc("fpe2")) {
            uint16_t number = (uint16_t)(value * 4); output->bytes[0] = number >> 8; output->bytes[1] = number & 255;
        }
    }
    return KERN_SUCCESS;
}
int main(void) {
    connection = 1; smc_attempted = true;
    for (int i = 0; i < MT_MAX_FANS; ++i) types[i] = fourcc("flt ");
    MTFanReading r = mt_fan_read();
    assert(r.count == 2 && r.valid_mask == 3 && r.rpm[0] == 1800 && r.rpm[1] == 2100);
    speeds[0] = 0; types[1] = fourcc("fpe2"); speeds[1] = 2345.5;
    r = mt_fan_read(); assert(r.valid_mask == 3 && r.rpm[0] == 0 && r.rpm[1] == 2345.5);
    missing = 1; r = mt_fan_read(); assert(r.count == 2 && r.valid_mask == 2);
    missing = 0; types[0] = fourcc("ui8 "); speeds[0] = 42;
    r = mt_fan_read(); assert(r.rpm[0] == 42 && r.valid_mask == 3);
    types[0] = fourcc("flt "); speeds[0] = NAN; speeds[1] = 0;
    r = mt_fan_read(); assert(r.valid_mask == 2 && r.rpm[1] == 0);
    speeds[0] = -1; r = mt_fan_read(); assert(r.valid_mask == 2);
    speeds[0] = 30001; r = mt_fan_read(); assert(r.valid_mask == 2);
    types[0] = fourcc("xxxx"); r = mt_fan_read(); assert(r.valid_mask == 2);
    count_value = 0; r = mt_fan_read(); assert(r.count == 0 && r.valid_mask == 0);
    double invalid[] = {-1, 1.5, 9, NAN, INFINITY};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(*invalid); ++i) {
        count_value = invalid[i]; r = mt_fan_read(); assert(r.count == -1 && r.valid_mask == 0);
    }
    missing_count = true; r = mt_fan_read(); assert(r.count == -1);
    printf("PASS fan metrics: float/fpe2/ui8, stopped/absent/missing/partial/invalid, only read commands; %d calls\n", calls);
    connection = 0;
}
