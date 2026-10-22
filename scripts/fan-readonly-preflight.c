/* Explicit local investigation, NOT a production collector or a fan writer.
 * Reuses the existing attributed read-only SMC decoder. No command 6 exists. */
#include "../Sources/ThermalSensors.c"

int main(void) {
    double count;
    if (!smc_read_number("FNum", &count) || count < 0 || count > MT_MAX_FANS || floor(count) != count) {
        puts("Fan count unavailable; control capability unverified.");
        mt_thermal_close();
        return 1;
    }
    printf("Read-only preflight; fan count: %.0f\n", count);
    for (int i = 0; i < (int)count; ++i) {
        const char *suffixes[] = {"Ac", "Mn", "Mx", "Tg", "Md", "md"};
        for (size_t j = 0; j < sizeof(suffixes) / sizeof(*suffixes); ++j) {
            char key[5];
            snprintf(key, sizeof(key), "F%d%s", i, suffixes[j]);
            double number;
            if (smc_read_number(key, &number)) printf("%s: %.2f\n", key, number);
            else printf("%s: unavailable\n", key);
        }
    }
    double gate;
    if (smc_read_number("Ftst", &gate)) printf("Ftst: %.0f\n", gate);
    else puts("Ftst: unavailable");
    puts("Reading a key does not prove write access or successful restoration.");
    mt_thermal_close();
    return 0;
}
