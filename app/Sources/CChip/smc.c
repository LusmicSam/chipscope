// AppleSMC user client (read-only). On Apple Silicon the SMC is a coprocessor inside the SoC.
#include "cchip.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } smc_vers;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } smc_plimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } smc_keyinfo;
typedef struct {
    uint32_t key; smc_vers vers; smc_plimit plimit; smc_keyinfo info;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} smc_data;  // 80 bytes, the kernel's layout

static io_connect_t g_conn;

static uint32_t fourcc(const char k[4]) { return ((uint32_t)k[0] << 24) | ((uint32_t)k[1] << 16) | ((uint32_t)k[2] << 8) | (uint32_t)k[3]; }

static int call(smc_data *in, smc_data *out) {
    size_t sz = sizeof(smc_data);
    return IOConnectCallStructMethod(g_conn, 2, in, sizeof(smc_data), out, &sz) == kIOReturnSuccess ? 0 : -1;
}

int cc_smc_open(void) {
    _Static_assert(sizeof(smc_data) == 80, "SMC struct layout");
    if (g_conn) return 0;
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!s) return -1;
    kern_return_t r = IOServiceOpen(s, mach_task_self(), 0, &g_conn);
    IOObjectRelease(s);
    return r == kIOReturnSuccess ? 0 : -2;
}

int cc_smc_read(const char key[4], char type[5], unsigned char bytes[32]) {
    smc_data in, out;
    memset(&in, 0, sizeof in);
    in.key = fourcc(key);
    in.data8 = 9;  // key info
    if (call(&in, &out) || out.result) return -1;
    uint32_t size = out.info.dataSize, t = out.info.dataType;
    type[0] = (char)(t >> 24); type[1] = (char)(t >> 16); type[2] = (char)(t >> 8); type[3] = (char)t; type[4] = 0;
    memset(&in, 0, sizeof in);
    in.key = fourcc(key);
    in.info.dataSize = size;
    in.data8 = 5;  // read bytes
    if (call(&in, &out) || out.result) return -1;
    if (size > 32) size = 32;
    memcpy(bytes, out.bytes, size);
    return (int)size;
}

int cc_smc_key_count(void) {
    char type[5];
    unsigned char b[32];
    if (cc_smc_read("#KEY", type, b) < 4) return 0;
    return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
}

int cc_smc_key_at(int index, char out_key[5]) {
    smc_data in, out;
    memset(&in, 0, sizeof in);
    in.data8 = 8;
    in.data32 = (uint32_t)index;
    if (call(&in, &out)) return -1;
    out_key[0] = (char)(out.key >> 24); out_key[1] = (char)(out.key >> 16); out_key[2] = (char)(out.key >> 8);
    out_key[3] = (char)out.key; out_key[4] = 0;
    return 0;
}
