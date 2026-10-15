#ifndef THERMAL_SENSORS_H
#define THERMAL_SENSORS_H

typedef struct {
    double cpu_celsius;
    double ssd_celsius;
    int cpu_sensor_count;
    int ssd_sensor_count;
    char cpu_source[128];
    char ssd_source[128];
} MTThermalReading;

MTThermalReading mt_thermal_read(void);
void mt_thermal_close(void);

#endif
