#include "CBenchKit.h"

#include <stdio.h>

#if defined(_WIN32)
#define PSAPI_VERSION 2 /* route GetProcessMemoryInfo to kernel32's K32 export */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>

uint64_t benchkit_peak_rss_bytes(void) {
    PROCESS_MEMORY_COUNTERS pmc;
    pmc.cb = sizeof(pmc);
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, pmc.cb)) {
        return 0;
    }
    return (uint64_t)pmc.PeakWorkingSetSize;
}
#else
#include <sys/resource.h>

uint64_t benchkit_peak_rss_bytes(void) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        return 0;
    }
#if defined(__APPLE__)
    return (uint64_t)usage.ru_maxrss; /* bytes */
#else
    return (uint64_t)usage.ru_maxrss * 1024; /* kilobytes */
#endif
}
#endif

void benchkit_write_stderr(const char *bytes, size_t count) {
    fwrite(bytes, 1, count, stderr);
    fflush(stderr);
}
