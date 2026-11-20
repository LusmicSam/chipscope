// Named temperature sensors through the private IOHIDEventSystemClient API, loaded with dlsym
// (declaring it would clash with newer public headers).
#include "cchip.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <time.h>

typedef CFTypeRef (*ClientCreate_t)(CFAllocatorRef);
typedef int (*SetMatching_t)(CFTypeRef, CFDictionaryRef);
typedef CFArrayRef (*CopyServices_t)(CFTypeRef);
typedef CFTypeRef (*CopyProperty_t)(CFTypeRef, CFStringRef);
typedef CFTypeRef (*CopyEvent_t)(CFTypeRef, int64_t, int32_t, int64_t);
typedef double (*GetFloat_t)(CFTypeRef, int32_t);

static CopyEvent_t copyEvent;
static GetFloat_t getFloat;
static CFArrayRef g_services;
static int g_n;
static char g_names[128][64];

int cc_hid_open(void) {
    if (g_services) return g_n;
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) return 0;
    ClientCreate_t create = dlsym(h, "IOHIDEventSystemClientCreate");
    SetMatching_t setMatching = dlsym(h, "IOHIDEventSystemClientSetMatching");
    CopyServices_t copyServices = dlsym(h, "IOHIDEventSystemClientCopyServices");
    CopyProperty_t copyProperty = dlsym(h, "IOHIDServiceClientCopyProperty");
    copyEvent = dlsym(h, "IOHIDServiceClientCopyEvent");
    getFloat = dlsym(h, "IOHIDEventGetFloatValue");
    if (!create || !setMatching || !copyServices || !copyProperty || !copyEvent || !getFloat) return 0;
    CFTypeRef client = create(kCFAllocatorDefault);
    if (!client) return 0;
    int page = 0xFF00, usage = 5;  // Apple vendor page, temperature sensor
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberIntType, &page), nu = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *vals[] = {np, nu};
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    setMatching(client, match);
    CFRelease(match); CFRelease(np); CFRelease(nu);
    g_services = copyServices(client);  // keeps client + services alive for the app's lifetime
    if (!g_services) return 0;
    CFIndex n = CFArrayGetCount(g_services);
    if (n > 128) n = 128;
    for (CFIndex i = 0; i < n; i++) {
        CFTypeRef name = copyProperty(CFArrayGetValueAtIndex(g_services, i), CFSTR("Product"));
        g_names[i][0] = 0;
        if (name && CFGetTypeID(name) == CFStringGetTypeID()) CFStringGetCString(name, g_names[i], 64, kCFStringEncodingUTF8);
        if (name) CFRelease(name);
    }
    g_n = (int)n;
    return g_n;
}

const char *cc_hid_name(int i) { return (i >= 0 && i < g_n) ? g_names[i] : ""; }

double cc_hid_read(int i, double *read_us) {
    if (i < 0 || i >= g_n) return -999;
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    CFTypeRef ev = copyEvent(CFArrayGetValueAtIndex(g_services, i), 15, 0, 0);  // 15 = temperature
    clock_gettime(CLOCK_MONOTONIC, &b);
    *read_us = (b.tv_sec - a.tv_sec) * 1e6 + (b.tv_nsec - a.tv_nsec) / 1e3;
    if (!ev) return -999;
    double v = getFloat(ev, 15 << 16);
    CFRelease(ev);
    return v;
}
