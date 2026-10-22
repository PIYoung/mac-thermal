/* In-memory SMC fixtures only. No SMC connection, power notification or root. */
#include <assert.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
static kern_return_t fixture_call(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);
#define IOConnectCallStructMethod fixture_call
#include "../../Helper/FanHardware.c"
static double fixture_count = 2, actuals[8] = {1500, 1700}, targets[8] = {1500, 1700};
static int modes[8], writes, fail_write_at = -1;
static bool lowercase, busy_gate, missing_actual, fail_mode_readback;
static kern_return_t fixture_call(mach_port_t port, uint32_t selector, const void *raw,
                                  size_t length, void *result, size_t *result_size) {
    assert(port == 1 && selector == 2 && length == sizeof(SMCData) && *result_size == length);
    const SMCData *input = raw; SMCData *out = result;
    assert(input->command == 5 || input->command == 9 || input->command == 6);
    uint32_t suffix = input->key & 65535u;
    int i = (int)((input->key >> 16) & 255) - '0';
    bool count = input->key == fourcc("FNum"), gate = input->key == fourcc("Ftst");
    bool mode = suffix == (fourcc(lowercase ? "F0md" : "F0Md") & 65535u);
    bool actual = suffix == (fourcc("F0Ac") & 65535u);
    bool target = suffix == (fourcc("F0Tg") & 65535u);
    bool minimum = suffix == (fourcc("F0Mn") & 65535u);
    bool maximum = suffix == (fourcc("F0Mx") & 65535u);
    if ((!count && !gate && (i < 0 || i >= 8 || !(mode || actual || target || minimum || maximum))) ||
        (actual && missing_actual)) { out->result = 1; return KERN_SUCCESS; }
    if (input->command == 6) {
        assert(!count && !gate && (mode || target)); /* No global or arbitrary writes. */
        ++writes;
        if (writes == fail_write_at) { out->result = 1; return KERN_SUCCESS; }
        if (mode) { assert(input->bytes[0] <= 1); modes[i] = input->bytes[0]; }
        else { float value; memcpy(&value, input->bytes, 4); assert(value >= actuals[i] && value <= 4900); targets[i] = value; }
        return KERN_SUCCESS;
    }
    bool byte = count || gate || mode;
    if (input->command == 9) {
        out->key_info.type = fourcc(byte ? "ui8 " : "flt "); out->key_info.size = byte ? 1 : 4;
    } else {
        double value = count ? fixture_count : gate ? (busy_gate ? 1 : 0) : mode ? modes[i] : actual ? actuals[i] : target ? targets[i] : minimum ? 1000 : 4900;
        if (mode && fail_mode_readback) value = 1;
        if (byte) out->bytes[0] = (uint8_t)value;
        else { float encoded = (float)value; memcpy(out->bytes, &encoded, 4); }
    }
    return KERN_SUCCESS;
}
int main(void) {
    connection = 1; smc_attempted = true;
    assert(mtfc_start(1000) == 0 && writes == 0);
    assert(mtfc_start(5000) == 0 && writes == 0);
    assert(mtfc_start(1750) == 0 && writes == 0);
    assert(mtfc_start(3000) == 1 && modes[0] == 1 && modes[1] == 1 && targets[0] == 3000);
    missing_actual = true; /* Restore cannot depend on RPM/temperature availability. */
    assert(mtfc_restore(2) == 1 && modes[0] == 0 && modes[1] == 0);
    missing_actual = false;
    writes = 0; fail_write_at = 4;
    assert(mtfc_start(3000) == 0 && writes == 4);
    fail_write_at = -1;
    assert(mtfc_restore(2) == 1);
    lowercase = true;
    assert(mtfc_start(4000) == 1 && mtfc_restore(2) == 1);
    writes = 0; busy_gate = true;
    assert(mtfc_start(4000) == 0 && mtfc_restore(2) == 0 && writes == 0);
    busy_gate = false; fail_mode_readback = true;
    assert(mtfc_restore(2) == 0); /* Never claim auto from a successful write alone. */
    fail_mode_readback = false; modes[0] = modes[1] = 0;
    fixture_count = 0; assert(mtfc_start(3000) == 0);
    fixture_count = 2; assert(mtfc_restore(1) == 0);
    connection = 0;
    puts("PASS fan writer: fixed key allowlist, RPM range/current/step checks, per-fan legacy/lowercase modes, partial writes, restore without RPM reads, mode readback, foreign gate refusal; synthetic only");
}
