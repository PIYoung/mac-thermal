#ifndef MT_FAN_HARDWARE_H
#define MT_FAN_HARDWARE_H
#include <stdint.h>
typedef struct {
    int count;
    unsigned int valid_mask;
    double actual[8], minimum[8], maximum[8], target[8];
    int mode[8];
    unsigned int lowercase_mask;
    int gate; /* -1 absent/unreadable; 0 normal; nonzero: refuse new control */
} MTFanControlReading;
MTFanControlReading mtfc_read(void);
int mtfc_start(int rpm);
int mtfc_restore(int expected_count);
double mtfc_cpu_temperature(void); /* 0 means unavailable */
void mtfc_reset_connection(void);
int mtfc_watch_power(void (*callback)(void *, int), void *context);
#endif
