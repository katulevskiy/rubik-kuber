#pragma once
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <string>
#include <vector>

// ── ANSI colours ────────────────────────────────────────────────────────────
#define COL_RESET  "\033[0m"
#define COL_BOLD   "\033[1m"
#define COL_GREEN  "\033[32m"
#define COL_YELLOW "\033[33m"
#define COL_RED    "\033[31m"
#define COL_CYAN   "\033[36m"
#define COL_WHITE  "\033[97m"

// ── Result ──────────────────────────────────────────────────────────────────
struct TestResult {
    std::string subsystem;   // "CPU-OpenCL", "GPU-OpenCL", "NPU-HTP", etc.
    bool        ok   = false;
    std::string note;        // brief detail or error message
    double      ms   = 0;   // wall-clock time for the main operation
    double      gops = 0;   // computed GFLOP/s or GB/s (if applicable)
};

// ── Global result accumulator ────────────────────────────────────────────────
inline std::vector<TestResult>& results() {
    static std::vector<TestResult> r;
    return r;
}

inline void push_result(TestResult r) { results().push_back(std::move(r)); }

// ── Timing helper ────────────────────────────────────────────────────────────
struct Timer {
    std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
    double elapsed_ms() const {
        auto t1 = std::chrono::steady_clock::now();
        return std::chrono::duration<double, std::milli>(t1 - t0).count();
    }
    void reset() { t0 = std::chrono::steady_clock::now(); }
};

// ── Section header ───────────────────────────────────────────────────────────
inline void section(const char* title) {
    printf("\n" COL_CYAN COL_BOLD
           "══════════════════════════════════════════════════\n"
           "  %s\n"
           "══════════════════════════════════════════════════" COL_RESET "\n",
           title);
}

inline void ok_msg (const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    printf("  " COL_GREEN "✓  " COL_RESET); vprintf(fmt, ap); printf("\n");
    va_end(ap);
}
inline void warn_msg(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    printf("  " COL_YELLOW "!  " COL_RESET); vprintf(fmt, ap); printf("\n");
    va_end(ap);
}
inline void err_msg (const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    printf("  " COL_RED "✗  " COL_RESET); vprintf(fmt, ap); printf("\n");
    va_end(ap);
}
inline void info_msg(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    printf("     "); vprintf(fmt, ap); printf("\n");
    va_end(ap);
}
