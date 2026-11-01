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

uint32_t benchkit_cpu_count(void) {
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    return (uint32_t)info.dwNumberOfProcessors;
}
#else
#include <sys/resource.h>
#include <unistd.h>

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

uint32_t benchkit_cpu_count(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (uint32_t)n : 0;
}
#endif

void benchkit_write_stderr(const char *bytes, size_t count) {
    fwrite(bytes, 1, count, stderr);
    fflush(stderr);
}
