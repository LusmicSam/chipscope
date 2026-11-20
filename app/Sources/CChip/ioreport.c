// IOReport via dlopen: the same private counters Activity Monitor / powermetrics use. No sudo.
#include "cchip.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <string.h>
#include <time.h>

typedef CFMutableDictionaryRef (*CopyChannelsInGroup_t)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void (*MergeChannels_t)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef void *(*CreateSubscription_t)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*CreateSamples_t)(void *, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*CreateSamplesDelta_t)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*GetStr_t)(CFDictionaryRef);
typedef uint8_t (*GetFormat_t)(CFDictionaryRef);
typedef int64_t (*SimpleGet_t)(CFDictionaryRef, int32_t);
typedef int32_t (*StateCount_t)(CFDictionaryRef);
typedef CFStringRef (*StateName_t)(CFDictionaryRef, int32_t);
typedef int64_t (*StateRes_t)(CFDictionaryRef, int32_t);

static struct {
    CopyChannelsInGroup_t copy; MergeChannels_t merge; CreateSubscription_t sub; CreateSamples_t samples;
    CreateSamplesDelta_t delta; GetStr_t group, subgroup, name, unit; GetFormat_t format; SimpleGet_t simple;
    StateCount_t scount; StateName_t sname; StateRes_t sres;
} F;
static void *g_sub;
static CFMutableDictionaryRef g_subbed;
static CFDictionaryRef g_prev;
static double g_prev_t;

static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }

static void cfcopy(CFStringRef s, char *out, int n) {
    out[0] = 0;
    if (s) CFStringGetCString(s, out, n, kCFStringEncodingUTF8);
}

int cc_ior_open(void) {
    if (g_sub) return 0;
    void *h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
    if (!h) return -1;
#define L(field, sym) F.field = dlsym(h, sym); if (!F.field) return -2;
    L(copy, "IOReportCopyChannelsInGroup") L(merge, "IOReportMergeChannels") L(sub, "IOReportCreateSubscription")
    L(samples, "IOReportCreateSamples") L(delta, "IOReportCreateSamplesDelta") L(group, "IOReportChannelGetGroup")
    L(subgroup, "IOReportChannelGetSubGroup") L(name, "IOReportChannelGetChannelName") L(unit, "IOReportChannelGetUnitLabel")
    L(format, "IOReportChannelGetFormat") L(simple, "IOReportSimpleGetIntegerValue") L(scount, "IOReportStateGetCount")
    L(sname, "IOReportStateGetNameForIndex") L(sres, "IOReportStateGetResidency")
#undef L
    const char *groups[][2] = {{"AMC Stats", "Perf Counters"}, {"Energy Model", NULL},
                               {"CPU Stats", "CPU Core Performance States"}, {"CPU Stats", "CPU Complex Performance States"},
                               {"GPU Stats", "GPU Performance States"}, {"Bandwidth", NULL}};
    CFMutableDictionaryRef base = NULL;
    for (int i = 0; i < 6; i++) {
        CFStringRef g = CFStringCreateWithCString(NULL, groups[i][0], kCFStringEncodingUTF8);
        CFStringRef sg = groups[i][1] ? CFStringCreateWithCString(NULL, groups[i][1], kCFStringEncodingUTF8) : NULL;
        CFMutableDictionaryRef d = F.copy(g, sg, 0, 0, 0);
        CFRelease(g);
        if (sg) CFRelease(sg);
        if (!d) continue;
        if (!base) base = d; else { F.merge(base, d, NULL); CFRelease(d); }
    }
    if (!base) return -3;
    CFMutableDictionaryRef chans = CFDictionaryCreateMutableCopy(NULL, 0, base);
    CFRelease(base);
    g_sub = F.sub(NULL, chans, &g_subbed, 0, NULL);
    if (!g_sub) return -4;
    g_prev = F.samples(g_sub, g_subbed, NULL);
    g_prev_t = now_s();
    return 0;
}

int cc_ior_sample(cc_item *out, int max, double *dt_seconds) {
    if (!g_sub) return -1;
    CFDictionaryRef cur = F.samples(g_sub, g_subbed, NULL);
    double t = now_s();
    *dt_seconds = t - g_prev_t > 1e-3 ? t - g_prev_t : 1e-3;
    CFDictionaryRef d = F.delta(g_prev, cur, NULL);
    CFRelease(g_prev);
    g_prev = cur;
    g_prev_t = t;
    if (!d) return 0;
    CFArrayRef arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
    int n = 0;
    CFIndex count = arr ? CFArrayGetCount(arr) : 0;
    for (CFIndex i = 0; i < count && n < max; i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(arr, i);
        int fmt = F.format(ch);
        if (fmt != 1 && fmt != 2) continue;
        cc_item *it = &out[n++];
        memset(it, 0, sizeof(*it));
        it->format = fmt;
        cfcopy(F.group(ch), it->group, sizeof it->group);
        cfcopy(F.subgroup(ch), it->subgroup, sizeof it->subgroup);
        cfcopy(F.name(ch), it->name, sizeof it->name);
        cfcopy(F.unit(ch), it->unit, sizeof it->unit);
        if (fmt == 1) {
            it->value = F.simple(ch, 0);
        } else {
            int k = F.scount(ch);
            if (k > CC_MAX_STATES) k = CC_MAX_STATES;
            it->nstates = k;
            for (int s = 0; s < k; s++) {
                cfcopy(F.sname(ch, s), it->snames[s], sizeof it->snames[s]);
                it->sres[s] = F.sres(ch, s);
            }
        }
    }
    CFRelease(d);
    return n;
}
