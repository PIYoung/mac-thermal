#ifndef THERMAL_SENSORS_H
#define THERMAL_SENSORS_H

typedef struct {
    double cpu_celsius;
    double ssd_celsius;
    int cpu_sensor_count;
    int ssd_sensor_count;
    char cpu_source[128];
    char ssd_source[128];
    double gpu_celsius;
    double memory_proximity_celsius;
    int gpu_sensor_count;
    int memory_proximity_sensor_count;
} MTThermalReading;

#define MT_MAX_FANS 8
/* count == -1: unavailable. count == 0: SMC explicitly reports no fans.
 * A clear bit in valid_mask is unknown, never a stopped fan. */
typedef struct {
    int count;
    unsigned int valid_mask;
    double rpm[MT_MAX_FANS];
} MTFanReading;

MTFanReading mt_fan_read(void);
MTThermalReading mt_thermal_read(void);
void mt_thermal_close(void);

#endif
