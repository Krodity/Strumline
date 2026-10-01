#ifndef CATOMICS_H
#define CATOMICS_H
#include <stdint.h>

// Tiny lock-free helpers for the audio thread (Swift's Synchronization
// module needs iOS 18; we target 17).
static inline int64_t sl_load64(const int64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void sl_store64(int64_t *p, int64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static inline double sl_loadd(const double *p) { double v; __atomic_load(p, &v, __ATOMIC_ACQUIRE); return v; }
static inline void sl_stored(double *p, double v) { __atomic_store(p, &v, __ATOMIC_RELEASE); }
#endif
