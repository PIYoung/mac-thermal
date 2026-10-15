#include "ThermalSensors.h"
#include <stdio.h>

int main(void) {
    MTThermalReading reading = mt_thermal_read();
    printf("CPU=%.2f C sensors=%d source=%s\nSSD=%.2f C sensors=%d source=%s\n", reading.cpu_celsius, reading.cpu_sensor_count, reading.cpu_source, reading.ssd_celsius, reading.ssd_sensor_count, reading.ssd_source);
    mt_thermal_close();
    return reading.cpu_sensor_count && reading.ssd_sensor_count ? 0 : 1;
}
