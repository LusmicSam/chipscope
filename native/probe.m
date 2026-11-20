// chipscope-probe: signal-timing probes and load generators for Apple Silicon.
//
// Every command prints JSON lines on stdout and exits by itself; load
// generators also stop on SIGTERM/SIGINT. Built by start.sh with clang.
//
//   memlat  --qos p|e [--max-mb 256]     pointer-chase latency vs working-set size
//   c2c     [--seconds 4]                core-to-core cache-line ping-pong
//   ssdlat  --file PATH [--mb 128] [--n 400]   16 KiB uncached random reads
//   gpulat  [--n 200]                    empty Metal dispatch round trip
//   anelat  [--n 20]                     Vision request round trip (Neural Engine)
//   misc                                 syscall, thread wake, timer read
//   burn    cpu|mem|gpu|ane|ssd [--seconds 20] [--threads N] [--qos p|e] [--file PATH]

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <sys/qos.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static double g_ns_per_tick = 1.0;
static volatile sig_atomic_t g_stop = 0;
static volatile uintptr_t g_sink = 0;

static uint64_t ticks(void) { return mach_absolute_time(); }
static double tns(uint64_t t) { return (double)t * g_ns_per_tick; }
static double now_s(void) { return tns(ticks()) / 1e9; }
static size_t cpu_now(void) { size_t n = (size_t)-1; pthread_cpu_number_np(&n); return n; }

static void set_qos(const char *q) {
    qos_class_t c = (q && q[0] == 'e') ? QOS_CLASS_BACKGROUND : QOS_CLASS_USER_INTERACTIVE;
    pthread_set_qos_class_self_np(c, 0);
}

static const char *opt(int argc, char **argv, const char *name, const char *def) {
    for (int i = 0; i < argc - 1; i++) if (!strcmp(argv[i], name)) return argv[i + 1];
    return def;
}
static long opti(int argc, char **argv, const char *name, long def) {
    const char *v = opt(argc, argv, name, NULL);
    return v ? strtol(v, NULL, 10) : def;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}
static void print_dist(const char *kind, double *v, int n, const char *unit) {
    qsort(v, n, sizeof(double), cmp_double);
    printf("{\"kind\":\"%s\",\"n\":%d,\"unit\":\"%s\",\"p10\":%.3f,\"p50\":%.3f,\"p90\":%.3f,\"min\":%.3f}\n",
           kind, n, unit, v[n / 10], v[n / 2], v[(n * 9) / 10], v[0]);
    fflush(stdout);
}

static void on_signal(int s) { (void)s; g_stop = 1; }

// ---------------------------------------------------------------- memlat
// Random pointer chase at cache-line stride: each load depends on the one
// before, so time per step = latency of whichever level holds the set.
static void cmd_memlat(int argc, char **argv) {
    set_qos(opt(argc, argv, "--qos", "p"));
    const size_t line = 128;  // hw.cachelinesize on M1
    size_t maxb = (size_t)opti(argc, argv, "--max-mb", 256) << 20;
    char *buf = NULL;
    if (posix_memalign((void **)&buf, 16384, maxb)) { printf("{\"error\":\"alloc\"}\n"); return; }
    memset(buf, 1, maxb);
    size_t *idx = malloc((maxb / line) * sizeof(size_t));
    double size_f = 4096;
    while ((size_t)size_f <= maxb && !g_stop) {
        size_t size = ((size_t)size_f / line) * line;
        size_t n = size / line;
        for (size_t i = 0; i < n; i++) idx[i] = i;
        for (size_t i = n - 1; i > 0; i--) {  // Sattolo: one single cycle through all lines
            size_t j = arc4random_uniform((uint32_t)i);
            size_t t = idx[i]; idx[i] = idx[j]; idx[j] = t;
        }
        for (size_t i = 0; i < n; i++)
            *(void **)(buf + idx[i] * line) = buf + idx[(i + 1) % n] * line;
        void **p = (void **)(buf + idx[0] * line);
        for (size_t k = 0; k < n * 2; k++) p = (void **)*p;  // warm
        size_t iters = 1 << 14;
        for (;;) {  // size one run to >= 8 ms
            uint64_t t0 = ticks();
            for (size_t k = 0; k < iters; k += 8) {
                p = (void **)*p; p = (void **)*p; p = (void **)*p; p = (void **)*p;
                p = (void **)*p; p = (void **)*p; p = (void **)*p; p = (void **)*p;
            }
            if (tns(ticks() - t0) >= 8e6 || iters >= (1ul << 28)) break;
            iters *= 2;
        }
        // Best of 5 runs: a run the scheduler interrupted (or moved) only gets slower,
        // so the minimum is the closest to the hardware's own latency.
        double ns = 1e18;
        for (int rep = 0; rep < 5; rep++) {
            uint64_t t0 = ticks();
            for (size_t k = 0; k < iters; k += 8) {
                p = (void **)*p; p = (void **)*p; p = (void **)*p; p = (void **)*p;
                p = (void **)*p; p = (void **)*p; p = (void **)*p; p = (void **)*p;
            }
            double v = tns(ticks() - t0) / iters;
            if (v < ns) ns = v;
        }
        g_sink += (uintptr_t)p;
        printf("{\"size\":%zu,\"ns\":%.3f,\"cpu\":%zu}\n", size, ns, cpu_now());
        fflush(stdout);
        size_f *= 1.41421356;
    }
    free(idx);
    free(buf);
}

// ---------------------------------------------------------------- c2c
// Two threads bounce one cache line. One-way latency = round trip / 2.
// Batches where either thread moved cores are discarded.
typedef struct {
    _Atomic uint64_t flag __attribute__((aligned(128)));
    char pad[120];
    _Atomic int go, abort_;
    long iters;
    const char *qos_a, *qos_b;
    size_t a_start, a_end, b_start, b_end;
    double rtt_ns;
} c2c_t;

static void *c2c_ping(void *arg) {
    c2c_t *c = arg;
    set_qos(c->qos_a);
    while (!atomic_load(&c->go)) {}
    c->a_start = cpu_now();
    uint64_t t0 = ticks();
    for (long i = 0; i < c->iters; i++) {
        atomic_store_explicit(&c->flag, 2 * i + 1, memory_order_release);
        long spins = 0;
        while (atomic_load_explicit(&c->flag, memory_order_acquire) != (uint64_t)(2 * i + 2)) {
            if (++spins > 4000000) { atomic_store(&c->abort_, 1); }
            if (atomic_load_explicit(&c->abort_, memory_order_relaxed)) goto out;
        }
    }
    c->rtt_ns = tns(ticks() - t0) / c->iters;
out:
    c->a_end = cpu_now();
    return NULL;
}

static void *c2c_pong(void *arg) {
    c2c_t *c = arg;
    set_qos(c->qos_b);
    atomic_store(&c->go, 1);
    c->b_start = cpu_now();
    for (long i = 0; i < c->iters; i++) {
        long spins = 0;
        while (atomic_load_explicit(&c->flag, memory_order_acquire) != (uint64_t)(2 * i + 1)) {
            if (++spins > 4000000) { atomic_store(&c->abort_, 1); }
            if (atomic_load_explicit(&c->abort_, memory_order_relaxed)) goto out;
        }
        atomic_store_explicit(&c->flag, 2 * i + 2, memory_order_release);
    }
out:
    c->b_end = cpu_now();
    return NULL;
}

static void cmd_c2c(int argc, char **argv) {
    double secs = (double)opti(argc, argv, "--seconds", 4);
    const char *combos[][2] = {{"p", "p"}, {"e", "e"}, {"p", "e"}, {"e", "p"}};
    double end = now_s() + secs;
    int k = 0, kept = 0, dropped = 0;
    while (now_s() < end && !g_stop) {
        c2c_t *c = NULL;
        posix_memalign((void **)&c, 128, sizeof(c2c_t));
        memset(c, 0, sizeof(*c));
        c->iters = 4000;
        c->qos_a = combos[k % 4][0];
        c->qos_b = combos[k % 4][1];
        k++;
        pthread_t a, b;
        pthread_create(&a, NULL, c2c_ping, c);
        pthread_create(&b, NULL, c2c_pong, c);
        pthread_join(a, NULL);
        pthread_join(b, NULL);
        if (!atomic_load(&c->abort_) && c->a_start == c->a_end && c->b_start == c->b_end &&
            c->a_start != c->b_start && c->rtt_ns > 0) {
            printf("{\"a\":%zu,\"b\":%zu,\"ns\":%.2f,\"qos\":\"%s%s\"}\n", c->a_start, c->b_start, c->rtt_ns / 2,
                   c->qos_a, c->qos_b);
            fflush(stdout);
            kept++;
        } else {
            const char *why = atomic_load(&c->abort_) ? "timeout" :
                              (c->a_start != c->a_end || c->b_start != c->b_end) ? "moved" :
                              c->a_start == c->b_start ? "same_core" : "other";
            printf("{\"drop\":\"%s\",\"qos\":\"%s%s\"}\n", why, c->qos_a, c->qos_b);
            dropped++;
        }
        free(c);
    }
    printf("{\"done\":true,\"kept\":%d,\"dropped\":%d}\n", kept, dropped);
}

// ---------------------------------------------------------------- ssd
static int ensure_file(const char *path, size_t bytes) {
    int fd = open(path, O_RDWR | O_CREAT, 0600);
    if (fd < 0) return -1;
    fcntl(fd, F_NOCACHE, 1);  // don't leave the written pages in the RAM file cache
    off_t sz = lseek(fd, 0, SEEK_END);
    if ((size_t)sz < bytes) {
        size_t chunk = 1 << 20;
        char *b = malloc(chunk);
        arc4random_buf(b, chunk);  // random data: nothing for the controller to compress
        lseek(fd, 0, SEEK_SET);
        for (size_t w = 0; w < bytes; w += chunk) { if (write(fd, b, chunk) < 0) break; }
        free(b);
        fsync(fd);
    }
    return fd;
}

static void cmd_ssdlat(int argc, char **argv) {
    const char *path = opt(argc, argv, "--file", NULL);
    if (!path) { printf("{\"error\":\"--file required\"}\n"); return; }
    size_t bytes = (size_t)opti(argc, argv, "--mb", 128) << 20;
    int n = (int)opti(argc, argv, "--n", 400);
    int fd = ensure_file(path, bytes);
    if (fd < 0) { printf("{\"error\":\"open\"}\n"); return; }
    fcntl(fd, F_NOCACHE, 1);  // new reads bypass the unified buffer cache
    // F_NOCACHE does not evict pages that are already cached, so drop them first:
    // msync(MS_INVALIDATE) on a mapping of the file throws its cached pages away.
    void *map = mmap(NULL, bytes, PROT_READ, MAP_SHARED, fd, 0);
    if (map != MAP_FAILED) { msync(map, bytes, MS_INVALIDATE); munmap(map, bytes); }
    const size_t bs = 16384;
    char *buf; posix_memalign((void **)&buf, 16384, bs);
    double *lat = malloc(sizeof(double) * n);
    uint32_t blocks = (uint32_t)(bytes / bs);
    for (int i = 0; i < n && !g_stop; i++) {
        off_t off = (off_t)arc4random_uniform(blocks) * bs;
        uint64_t t0 = ticks();
        if (pread(fd, buf, bs, off) != (ssize_t)bs) { lat[i] = 0; continue; }
        lat[i] = tns(ticks() - t0) / 1000.0;
    }
    print_dist("ssd_read_16k", lat, n, "us");
    close(fd);
    free(buf); free(lat);
}

// ---------------------------------------------------------------- metal
static NSString *kKernels =
    @"#include <metal_stdlib>\nusing namespace metal;\n"
     "kernel void noop(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { if (i == 0) o[0] = 1; }\n"
     "kernel void burn(device float4 *o [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
     "  float4 a = float4(i * 1e-7, 1.0001, 0.9999, 0.5); float4 b = float4(0.999, 1.0002, 0.25, 0.75);\n"
     "  for (int k = 0; k < 4096; k++) { a = fma(a, b, float4(1e-7)); b = fma(b, a, float4(-1e-7)); }\n"
     "  o[i & 1023] = a + b; }\n";

static id<MTLComputePipelineState> pipeline(id<MTLDevice> dev, NSString *name) {
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kKernels options:nil error:&err];
    if (!lib) { printf("{\"error\":\"metal compile: %s\"}\n", err.localizedDescription.UTF8String); exit(1); }
    return [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:name] error:&err];
}

static void cmd_gpulat(int argc, char **argv) {
    @autoreleasepool {
        int n = (int)opti(argc, argv, "--n", 200);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLComputePipelineState> ps = pipeline(dev, @"noop");
        id<MTLBuffer> out = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        double *rt = malloc(sizeof(double) * n), *gt = malloc(sizeof(double) * n);
        for (int i = -20; i < n; i++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:ps];
                [e setBuffer:out offset:0 atIndex:0];
                [e dispatchThreads:MTLSizeMake(32, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
                [e endEncoding];
                uint64_t t0 = ticks();
                [cb commit];
                [cb waitUntilCompleted];
                double us = tns(ticks() - t0) / 1000.0;
                if (i >= 0) { rt[i] = us; gt[i] = (cb.GPUEndTime - cb.GPUStartTime) * 1e6; }
            }
        }
        print_dist("gpu_roundtrip", rt, n, "us");
        print_dist("gpu_exec", gt, n, "us");
        printf("{\"kind\":\"gpu_name\",\"name\":\"%s\"}\n", dev.name.UTF8String);
        free(rt); free(gt);
    }
}

static void burn_gpu(double secs) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLComputePipelineState> ps = pipeline(dev, @"burn");
        id<MTLBuffer> out = [dev newBufferWithLength:1024 * 16 options:MTLResourceStorageModePrivate];
        double end = now_s() + secs;
        id<MTLCommandBuffer> last = nil;
        long batches = 0;
        while (now_s() < end && !g_stop) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:ps];
                [e setBuffer:out offset:0 atIndex:0];
                [e dispatchThreads:MTLSizeMake(1 << 18, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                [e endEncoding];
                [cb commit];
                if (last) [last waitUntilCompleted];  // keep two in flight
                last = cb;
                batches++;
            }
        }
        [last waitUntilCompleted];
        printf("{\"done\":true,\"batches\":%ld}\n", batches);
    }
}

// ---------------------------------------------------------------- vision / ANE
static CGImageRef test_image(void) {
    size_t w = 384, h = 384;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    for (int i = 0; i < 24; i++) {  // a busy synthetic scene so the model has work to do
        CGContextSetRGBFillColor(ctx, (i * 37 % 255) / 255.0, (i * 91 % 255) / 255.0, (i * 53 % 255) / 255.0, 1);
        CGContextFillEllipseInRect(ctx, CGRectMake((i * 61) % 300, (i * 97) % 300, 40 + i * 3, 30 + i * 2));
    }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return img;
}

static double vision_once(CGImageRef img) {
    @autoreleasepool {
        VNClassifyImageRequest *req = [[VNClassifyImageRequest alloc] init];
        VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:img options:@{}];
        NSError *err = nil;
        uint64_t t0 = ticks();
        [h performRequests:@[ req ] error:&err];
        double ms = tns(ticks() - t0) / 1e6;
        if (err) { printf("{\"error\":\"vision: %s\"}\n", err.localizedDescription.UTF8String); return -1; }
        return ms;
    }
}

static void cmd_anelat(int argc, char **argv) {
    int n = (int)opti(argc, argv, "--n", 20);
    CGImageRef img = test_image();
    vision_once(img);  // first call loads the model
    double *v = malloc(sizeof(double) * n);
    for (int i = 0; i < n; i++) v[i] = vision_once(img);
    print_dist("vision_classify", v, n, "ms");
    free(v);
    CGImageRelease(img);
}

static void burn_ane(double secs) {
    CGImageRef img = test_image();
    double end = now_s() + secs;
    long runs = 0;
    while (now_s() < end && !g_stop) { if (vision_once(img) < 0) break; runs++; }
    printf("{\"done\":true,\"runs\":%ld}\n", runs);
    CGImageRelease(img);
}

// ---------------------------------------------------------------- cpu / mem / ssd load
typedef struct { double end; const char *qos; double result; char *src, *dst; size_t len; } job_t;

static void *cpu_worker(void *arg) {
    job_t *j = arg;
    set_qos(j->qos);
    double a = 1.0001, b = 0.9999, c = 0.5;
    long it = 0;
    while (!g_stop) {
        for (int k = 0; k < 1 << 16; k++) { a = fma(a, b, 1e-9); b = fma(b, c, 1e-9); c = fma(c, a, -1e-9); }
        if (++it % 16 == 0 && now_s() > j->end) break;
    }
    j->result = a + b + c;
    return NULL;
}

static void *mem_worker(void *arg) {
    job_t *j = arg;
    set_qos(j->qos);
    double bytes = 0;
    double t0 = now_s();
    while (!g_stop && now_s() < j->end) {
        memcpy(j->dst, j->src, j->len);
        bytes += 2.0 * j->len;  // read + write
    }
    j->result = bytes / (now_s() - t0);
    return NULL;
}

static void *ssd_worker(void *arg) {
    job_t *j = arg;
    int fd = open(j->src, O_RDONLY);
    if (fd < 0) return NULL;
    fcntl(fd, F_NOCACHE, 1);
    off_t size = lseek(fd, 0, SEEK_END);
    size_t bs = 1 << 20;
    char *buf; posix_memalign((void **)&buf, 16384, bs);
    double bytes = 0, t0 = now_s();
    off_t off = 0;
    while (!g_stop && now_s() < j->end) {
        ssize_t r = pread(fd, buf, bs, off);
        if (r <= 0) { off = 0; continue; }
        bytes += r;
        off = (off + bs) % size;
    }
    j->result = bytes / (now_s() - t0);
    close(fd);
    free(buf);
    return NULL;
}

static void cmd_burn(int argc, char **argv) {
    if (argc < 1) { printf("{\"error\":\"burn what?\"}\n"); return; }
    const char *what = argv[0];
    double secs = (double)opti(argc, argv, "--seconds", 20);
    if (secs > 120) secs = 120;
    int threads = (int)opti(argc, argv, "--threads", 0);
    const char *qos = opt(argc, argv, "--qos", "p");
    double end = now_s() + secs;
    printf("{\"started\":\"%s\",\"seconds\":%.0f}\n", what, secs);
    fflush(stdout);
    if (!strcmp(what, "gpu")) { burn_gpu(secs); return; }
    if (!strcmp(what, "ane")) { burn_ane(secs); return; }
    if (threads <= 0) threads = !strcmp(what, "mem") ? 4 : !strcmp(what, "ssd") ? 1 : 6;
    if (threads > 16) threads = 16;
    job_t jobs[16];
    pthread_t th[16];
    size_t len = 32u << 20;  // 32 MiB per thread each way: past the 24 MiB SLC, so it streams DRAM
    for (int i = 0; i < threads; i++) {
        jobs[i] = (job_t){.end = end, .qos = qos};
        if (!strcmp(what, "mem")) {
            jobs[i].len = len;
            posix_memalign((void **)&jobs[i].src, 16384, len);
            posix_memalign((void **)&jobs[i].dst, 16384, len);
            memset(jobs[i].src, i + 1, len);
            memset(jobs[i].dst, 0, len);
            pthread_create(&th[i], NULL, mem_worker, &jobs[i]);
        } else if (!strcmp(what, "ssd")) {
            const char *path = opt(argc, argv, "--file", NULL);
            if (!path) { printf("{\"error\":\"--file required\"}\n"); return; }
            close(ensure_file(path, 128u << 20));
            jobs[i].src = (char *)path;
            pthread_create(&th[i], NULL, ssd_worker, &jobs[i]);
        } else {
            pthread_create(&th[i], NULL, cpu_worker, &jobs[i]);
        }
    }
    double total = 0;
    for (int i = 0; i < threads; i++) { pthread_join(th[i], NULL); total += jobs[i].result; }
    if (!strcmp(what, "mem")) {
        for (int i = 0; i < threads; i++) { free(jobs[i].src); free(jobs[i].dst); }
        printf("{\"done\":true,\"bytes_per_s\":%.0f}\n", total);
    } else if (!strcmp(what, "ssd")) {
        printf("{\"done\":true,\"bytes_per_s\":%.0f}\n", total);
    } else {
        printf("{\"done\":true,\"sink\":%.3f}\n", total);
    }
}

// ---------------------------------------------------------------- misc
static dispatch_semaphore_t s_ping, s_pong;
static void *wake_worker(void *arg) {
    long n = (long)arg;
    for (long i = 0; i < n; i++) {
        dispatch_semaphore_wait(s_ping, DISPATCH_TIME_FOREVER);
        dispatch_semaphore_signal(s_pong);
    }
    return NULL;
}

static void cmd_misc(void) {
    set_qos("p");
    const int N = 200000;
    uint64_t t0 = ticks();
    for (int i = 0; i < N; i++) g_sink += (uintptr_t)getppid();
    printf("{\"kind\":\"syscall\",\"p50\":%.3f,\"unit\":\"ns\"}\n", tns(ticks() - t0) / N);
    t0 = ticks();
    for (int i = 0; i < N; i++) g_sink += ticks();
    printf("{\"kind\":\"timer_read\",\"p50\":%.3f,\"unit\":\"ns\"}\n", tns(ticks() - t0) / N);
    const long W = 2000;
    s_ping = dispatch_semaphore_create(0);
    s_pong = dispatch_semaphore_create(0);
    pthread_t th;
    pthread_create(&th, NULL, wake_worker, (void *)W);
    double *v = malloc(sizeof(double) * W);
    for (long i = 0; i < W; i++) {
        uint64_t a = ticks();
        dispatch_semaphore_signal(s_ping);
        dispatch_semaphore_wait(s_pong, DISPATCH_TIME_FOREVER);
        v[i] = tns(ticks() - a) / 2000.0;  // one-way, in us
    }
    pthread_join(th, NULL);
    print_dist("thread_wake", v, (int)W, "us");
    free(v);
}

int main(int argc, char **argv) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    g_ns_per_tick = (double)tb.numer / tb.denom;
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) { fprintf(stderr, "usage: chipscope-probe memlat|c2c|ssdlat|gpulat|anelat|misc|burn ...\n"); return 2; }
    const char *cmd = argv[1];
    int ac = argc - 2;
    char **av = argv + 2;
    if (!strcmp(cmd, "memlat")) cmd_memlat(ac, av);
    else if (!strcmp(cmd, "c2c")) cmd_c2c(ac, av);
    else if (!strcmp(cmd, "ssdlat")) cmd_ssdlat(ac, av);
    else if (!strcmp(cmd, "gpulat")) cmd_gpulat(ac, av);
    else if (!strcmp(cmd, "anelat")) cmd_anelat(ac, av);
    else if (!strcmp(cmd, "misc")) cmd_misc();
    else if (!strcmp(cmd, "burn")) cmd_burn(ac, av);
    else { fprintf(stderr, "unknown command %s\n", cmd); return 2; }
    return 0;
}
