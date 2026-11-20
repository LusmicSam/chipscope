#ifndef CCHIP_H
#define CCHIP_H
#include <stdint.h>

// ---------------------------------------------------------------- IOReport
#define CC_MAX_STATES 24
typedef struct {
    char group[48];
    char subgroup[72];
    char name[64];
    char unit[16];
    int format;               // 1 = simple integer, 2 = state residency
    long long value;          // simple: delta since the previous sample
    int nstates;
    char snames[CC_MAX_STATES][16];
    long long sres[CC_MAX_STATES];
} cc_item;

// Subscribe to the groups chipscope reads. Returns 0 on success.
int cc_ior_open(void);
// Fill `out` with every channel's delta since the previous call. Returns the count (<= max).
int cc_ior_sample(cc_item *out, int max, double *dt_seconds);

// ---------------------------------------------------------------- SMC
int cc_smc_open(void);
int cc_smc_key_count(void);
int cc_smc_key_at(int index, char out_key[5]);
// Reads raw bytes; returns size (>0) or -1. `type` gets the 4-char type ("flt ", "ui8 ", ...).
int cc_smc_read(const char key[4], char type[5], unsigned char bytes[32]);

// ---------------------------------------------------------------- HID temperature sensors
int cc_hid_open(void);                     // returns number of sensors
const char *cc_hid_name(int i);
double cc_hid_read(int i, double *read_us); // celsius, or -999 when the sensor gives nothing

#endif
