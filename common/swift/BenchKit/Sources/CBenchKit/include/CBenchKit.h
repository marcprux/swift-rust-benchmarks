// Platform primitives that are awkward or impossible to reach from pure Swift on
// every supported OS (psapi is not in the WinSDK module; C's `stderr` is a global
// that Swift 6 strict concurrency rejects). Mirrors the `extern "C"` block in
// common/rust/benchkit.
#ifndef CBENCHKIT_H
#define CBENCHKIT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Peak resident set size of the current process, in bytes (0 if unavailable).
uint64_t benchkit_peak_rss_bytes(void);

/// Number of online logical processors (0 if unavailable).
uint32_t benchkit_cpu_count(void);

/// Writes `count` bytes to the standard error stream.
void benchkit_write_stderr(const char *bytes, size_t count);

#ifdef __cplusplus
}
#endif

#endif
