/* Original bounded fan writer; existing SMC ABI/decoder attribution is retained
 * in the included source and THIRD_PARTY_NOTICES.txt. Never linked into the app.
 * Only per-fan mode and target keys are writable. No global test/unlock writes. */
#include "FanHardware.h"
#include "../Sources/ThermalSensors.c"
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>

static bool write_number(const char key[5], double value) {
    if (!isfinite(value) || !smc_open()) return false;
    SMCData input = {0}, output = {0};
    input.key = fourcc(key); input.command = 9;
    if (!smc_call(&input, &output)) return false;
    input.key_info = output.key_info;
    if (output.key_info.type == fourcc("flt ") && output.key_info.size == 4) {
        float encoded = (float)value;
        memcpy(input.bytes, &encoded, sizeof(encoded));
    } else if (output.key_info.type == fourcc("fpe2") && output.key_info.size == 2 && value >= 0 && value <= 16383.75) {
        uint16_t encoded = (uint16_t)round(value * 4);
        input.bytes[0] = encoded >> 8; input.bytes[1] = encoded & 255;
    } else if (output.key_info.type == fourcc("ui8 ") && output.key_info.size == 1 && value >= 0 && value <= 255 && floor(value) == value) {
        input.bytes[0] = (uint8_t)value;
    } else return false;
    input.command = 6;
    return smc_call(&input, &output);
}

void mtfc_reset_connection(void) {
    if (connection) IOServiceClose(connection);
    connection = IO_OBJECT_NULL; smc_attempted = false;
}
static bool read_fan_count(double *count) {
    if (smc_read_number("FNum", count)) return true;
    mtfc_reset_connection();
    return smc_read_number("FNum", count); // One bounded reconnect after a lost driver endpoint.
}
MTFanControlReading mtfc_read(void) {
    MTFanControlReading r = {.count = -1, .gate = -1};
    double count, gate;
    if (!read_fan_count(&count) || count < 0 || count > 8 || floor(count) != count) return r;
    r.count = (int)count;
    if (smc_read_number("Ftst", &gate)) r.gate = gate == 0 ? 0 : 1;
    for (int i = 0; i < r.count; ++i) {
        char key[5] = {'F', (char)('0' + i), 'A', 'c', 0};
        if (!smc_read_number(key, &r.actual[i])) continue;
        key[2] = 'M'; key[3] = 'n'; if (!smc_read_number(key, &r.minimum[i])) continue;
        key[3] = 'x'; if (!smc_read_number(key, &r.maximum[i])) continue;
        key[2] = 'T'; key[3] = 'g'; if (!smc_read_number(key, &r.target[i])) continue;
        double mode;
        key[2] = 'm'; key[3] = 'd';
        if (smc_read_number(key, &mode)) r.lowercase_mask |= 1u << i;
        else { key[2] = 'M'; if (!smc_read_number(key, &mode)) continue; }
        if (mode != 0 && mode != 1) continue;
        r.mode[i] = (int)mode;
        if (r.actual[i] < 0 || r.actual[i] > 30000 || r.minimum[i] < 100 ||
            r.maximum[i] > 30000 || r.minimum[i] >= r.maximum[i] || r.actual[i] > r.maximum[i] + 100 ||
            r.target[i] < 0 || r.target[i] > 30000) continue;
        r.valid_mask |= 1u << i;
    }
    return r;
}

int mtfc_restore(int expected_count) {
    double count, gate;
    if (expected_count <= 0 || expected_count > 8 || !read_fan_count(&count) || count != expected_count) return 0;
    if (smc_read_number("Ftst", &gate) && gate != 0) return 0;
    bool ok = true;
    for (int i = 0; i < expected_count; ++i) {
        char key[5] = {'F', (char)('0' + i), 'm', 'd', 0};
        double mode;
        if (!smc_read_number(key, &mode)) { key[2] = 'M'; if (!smc_read_number(key, &mode)) { ok = false; continue; } }
        if (mode != 0 && mode != 1) { ok = false; continue; }
        // Always enqueue automatic for an owned lease, even if a stale read says 0.
        if (!write_number(key, 0)) { ok = false; continue; }
        double confirmed;
        if (!smc_read_number(key, &confirmed) || confirmed != 0) ok = false;
    }
    if (smc_read_number("Ftst", &gate) && gate != 0) return 0;
    return ok ? 1 : 0;
}

int mtfc_start(int rpm) {
    MTFanControlReading r = mtfc_read();
    if (r.count <= 0 || r.count > 8 || r.valid_mask != (1u << r.count) - 1u || r.gate > 0 || rpm % 100 != 0) return 0;
    for (int i = 0; i < r.count; ++i)
        if (r.mode[i] != 0 || rpm < r.minimum[i] || rpm < r.actual[i] || rpm > r.maximum[i]) return 0;
    for (int i = 0; i < r.count; ++i) {
        char key[5] = {'F', (char)('0' + i), (r.lowercase_mask & (1u << i)) ? 'm' : 'M', 'd', 0};
        if (!write_number(key, 1)) return 0; // Caller must restore the journaled lease even after partial failure.
        key[2] = 'T'; key[3] = 'g';
        if (!write_number(key, rpm)) return 0;
    }
    // Writes may become visible later. The service retains its journal and
    // confirms mode/target on later ticks within the bounded startup deadline.
    return 1;
}

double mtfc_cpu_temperature(void) {
    double hottest = 0;
    for (size_t i = 0; i < sizeof(cpu_keys) / sizeof(*cpu_keys); ++i) {
        double value;
        if (smc_read(cpu_keys[i], &value) && value > hottest) hottest = value;
    }
    return hottest;
}

static io_connect_t power_port;
static IONotificationPortRef power_notifications;
static io_object_t power_notifier;
static void (*sleep_callback)(void *, int);
static void *sleep_context;
static void power_event(void *unused, io_service_t service, natural_t type, void *argument) {
    (void)unused; (void)service;
    if (type == kIOMessageCanSystemSleep) IOAllowPowerChange(power_port, (long)argument);
    else if (type == kIOMessageSystemWillSleep) {
        if (sleep_callback) sleep_callback(sleep_context, 1);
        IOAllowPowerChange(power_port, (long)argument);
    } else if (type == kIOMessageSystemHasPoweredOn && sleep_callback) sleep_callback(sleep_context, 0);
}
int mtfc_watch_power(void (*callback)(void *, int), void *context) {
    sleep_callback = callback; sleep_context = context;
    power_port = IORegisterForSystemPower(NULL, &power_notifications, power_event, &power_notifier);
    if (!power_port || !power_notifications) return 0;
    CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(power_notifications);
    if (!source) return 0;
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    return 1;
}
