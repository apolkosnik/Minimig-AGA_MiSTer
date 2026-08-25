// Drive WinUAE's own softfloat (SOFTFLOAT_68K) with the same probe values
// the RTL was given, so the comparison is against WinUAE's 68040 code
// rather than against a reading of it.
#include <cstdio>
#include <cstdint>
#include "softfloat/softfloat.h"

struct P { const char *name; uint16_t se; uint32_t hi, lo; };

int main() {
    P probes[] = {
        {"2.5",            0x4000, 0xA0000000, 0x00000000},
        {"2.6",            0x4000, 0xA6666666, 0x66666666},
        {"-2.5",           0xC000, 0xA0000000, 0x00000000},
        {"2147483646.5",   0x401D, 0xFFFFFFFD, 0x00000000},
        {"2147483647.0",   0x401D, 0xFFFFFFFE, 0x00000000},
        {"2147483647.5",   0x401D, 0xFFFFFFFF, 0x00000000},
        {"2147483648.0",   0x401E, 0x80000000, 0x00000000},
        {"-2147483648.0",  0xC01E, 0x80000000, 0x00000000},
        {"-2147483649.0",  0xC01E, 0x80000001, 0x00000000},
        {"NaN all-ones",   0x7FFF, 0xFFFFFFFF, 0xFFFFFFFF},
        {"quiet NaN",      0x7FFF, 0xC0000000, 0x00000000},
        {"+Inf",           0x7FFF, 0x00000000, 0x00000000},
        {"-Inf",           0xFFFF, 0x00000000, 0x00000000},
    };
    printf("%-16s %-10s %s\n", "value", "result", "flags");
    for (auto &p : probes) {
        float_status fs;
        fs.float_detect_tininess = 0;
        fs.float_rounding_mode   = 0;   // round to nearest even
        fs.float_exception_flags = 0;
        fs.floatx80_rounding_precision = 80;
        fs.flush_to_zero = 0;
        fs.flush_inputs_to_zero = 0;
        fs.default_nan_mode = 0;
        fs.snan_bit_is_one = 0;
        floatx80 a;
        a.high = p.se;
        a.low  = ((uint64_t)p.hi << 32) | p.lo;
        int32_t r = floatx80_to_int32(a, &fs);
        printf("%-16s %08X   %s%s\n", p.name, (uint32_t)r,
               (fs.float_exception_flags & float_flag_invalid) ? "invalid(OPERR) " : "",
               (fs.float_exception_flags & float_flag_inexact) ? "inexact(INEX2)" : "");
    }
    return 0;
}
