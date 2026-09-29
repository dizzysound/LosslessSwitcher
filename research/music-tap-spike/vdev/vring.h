// Single-producer single-consumer stereo float ring + timestamp snapshots with proper memory
// ordering, for vrender.swift (bridging header). The producer is the virtual device's input IOProc,
// the consumer the DAC's output IOProc; the control thread only reads counters and snapshots.
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#define VR_FRAMES (1 << 20)
typedef struct {
    float data[VR_FRAMES * 2];
    _Atomic int64_t written;   // total frames written
    _Atomic int64_t read;      // total frames read
    _Atomic int64_t overruns;  // frames dropped (ring full)
    _Atomic int64_t underruns; // frames of silence substituted (ring empty while playing)
} vr_ring;

static inline int64_t vr_fill(vr_ring* r) { return atomic_load_explicit(&r->written, memory_order_acquire) - atomic_load_explicit(&r->read, memory_order_acquire); }

static inline void vr_write(vr_ring* r, const float* src, int64_t n) {
    int64_t w = atomic_load_explicit(&r->written, memory_order_relaxed);
    int64_t rd = atomic_load_explicit(&r->read, memory_order_acquire);
    int64_t space = VR_FRAMES - (w - rd);
    if (n > space) { atomic_fetch_add(&r->overruns, n - space); n = space; }
    for (int64_t i = 0; i < n; i++) { int64_t k = (w + i) & (VR_FRAMES - 1); r->data[2 * k] = src[2 * i]; r->data[2 * k + 1] = src[2 * i + 1]; }
    atomic_store_explicit(&r->written, w + n, memory_order_release);
}

// Reads n frames (zeros where the ring runs dry); returns frames actually taken from the ring.
static inline int64_t vr_read(vr_ring* r, float* dst, int64_t n) {
    int64_t rd = atomic_load_explicit(&r->read, memory_order_relaxed);
    int64_t w = atomic_load_explicit(&r->written, memory_order_acquire);
    int64_t avail = w - rd, take = n < avail ? n : avail;
    for (int64_t i = 0; i < take; i++) { int64_t k = (rd + i) & (VR_FRAMES - 1); dst[2 * i] = r->data[2 * k]; dst[2 * i + 1] = r->data[2 * k + 1]; }
    if (take < n) { memset(dst + 2 * take, 0, (size_t)(n - take) * 8); atomic_fetch_add(&r->underruns, n - take); }
    atomic_store_explicit(&r->read, rd + take, memory_order_release);
    return take;
}

// Timestamp snapshot (sample time, host time, rate scalar) written by an IO thread, read by the
// control thread; seqlock so a reader never pairs a sample time with another cycle's host time.
typedef struct { _Atomic uint64_t seq; double sample, host, scalar; } vr_stamp;
static inline void vr_stamp_put(vr_stamp* s, double sample, double host, double scalar) {
    uint64_t q = atomic_load_explicit(&s->seq, memory_order_relaxed);
    atomic_store_explicit(&s->seq, q + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    s->sample = sample; s->host = host; s->scalar = scalar;
    atomic_store_explicit(&s->seq, q + 2, memory_order_release);
}
static inline int vr_stamp_get(vr_stamp* s, double* sample, double* host, double* scalar) {
    for (int tries = 0; tries < 100; tries++) {
        uint64_t q1 = atomic_load_explicit(&s->seq, memory_order_acquire);
        if (q1 & 1) continue;
        double a = s->sample, b = s->host, c = s->scalar;
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&s->seq, memory_order_relaxed) == q1) { *sample = a; *host = b; *scalar = c; return q1 != 0; }
    }
    return 0;
}
static inline int64_t vr_overruns(vr_ring* r) { return atomic_load(&r->overruns); }
static inline int64_t vr_underruns(vr_ring* r) { return atomic_load(&r->underruns); }

// Like vr_read, but never reads at or past `limit` (a boundary marker; < 0 = none). Frames withheld
// because of the limit are zeros and don't count as underruns.
static inline int64_t vr_read_upto(vr_ring* r, float* dst, int64_t n, int64_t limit) {
    if (limit < 0) return vr_read(r, dst, n);
    int64_t rd = atomic_load_explicit(&r->read, memory_order_relaxed);
    int64_t allowed = limit - rd; if (allowed < 0) allowed = 0;
    int64_t m = n < allowed ? n : allowed;
    int64_t got = m > 0 ? vr_read(r, dst, m) : 0;
    if (m < n) memset(dst + 2 * m, 0, (size_t)(n - m) * 8);
    return got;
}
static inline int64_t vr_written(vr_ring* r) { return atomic_load_explicit(&r->written, memory_order_acquire); }
static inline int64_t vr_readpos(vr_ring* r) { return atomic_load_explicit(&r->read, memory_order_acquire); }
// Drain everything available into dst (up to max frames); returns frames.
static inline int64_t vr_drain(vr_ring* r, float* dst, int64_t max) {
    int64_t avail = vr_fill(r); if (avail > max) avail = max;
    return avail > 0 ? vr_read(r, dst, avail) : 0;
}
typedef struct { _Atomic int64_t v; } vr_i64;
static inline int64_t vr_get(vr_i64* a) { return atomic_load_explicit(&a->v, memory_order_acquire); }
static inline void vr_set(vr_i64* a, int64_t x) { atomic_store_explicit(&a->v, x, memory_order_release); }
// Drops frames from the read side so at most `keep` remain (startup: the ring filled while the
// consumer's device was still starting).
static inline void vr_trim(vr_ring* r, int64_t keep) {
    int64_t rd = atomic_load_explicit(&r->read, memory_order_relaxed);
    int64_t w = atomic_load_explicit(&r->written, memory_order_acquire);
    if (w - rd > keep) atomic_store_explicit(&r->read, w - keep, memory_order_release);
}
