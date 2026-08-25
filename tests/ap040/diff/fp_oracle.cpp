// Reference results for gen_fpops.py slots, computed by WinUAE's own
// softfloat (SOFTFLOAT_68K) exactly as fpp_softfloat.cpp drives it:
// same rounding-mode and precision mapping (fp_set_mode), same arithmetic
// entry points (floatx80_add/sub/mul/div/sqrt/abs/neg/cmp), and the same
// exception-flag to FPSR translation (fp_get_status).
//
// Build:
//   cd /home/adam/WinUAE
//   g++ -O0 -w -I. -o fp_oracle <this file> softfloat/softfloat.cpp
#include <cstdio>
#include <cstdint>
#include <cstring>
#include "softfloat/softfloat.h"

// FPSR bit positions, per WinUAE fpp.h
#define FPSR_BSUN   0x00008000
#define FPSR_SNAN   0x00004000
#define FPSR_OPERR  0x00002000
#define FPSR_OVFL   0x00001000
#define FPSR_UNFL   0x00000800
#define FPSR_DZ     0x00000400
#define FPSR_INEX2  0x00000200
#define FPSR_INEX1  0x00000100

static float_status fs;

static void set_mode(int prec, int rmode)
{
    set_float_detect_tininess(float_tininess_before_rounding, &fs);
    switch (prec) {                        // FPCR bits 7:6
        case 1:  set_floatx80_rounding_precision(32, &fs); break;
        case 2:  set_floatx80_rounding_precision(64, &fs); break;
        default: set_floatx80_rounding_precision(80, &fs); break;
    }
    switch (rmode) {                       // FPCR bits 5:4
        case 0: set_float_rounding_mode(float_round_nearest_even, &fs); break;
        case 1: set_float_rounding_mode(float_round_to_zero,      &fs); break;
        case 2: set_float_rounding_mode(float_round_down,         &fs); break;
        case 3: set_float_rounding_mode(float_round_up,           &fs); break;
    }
}

static uint32_t get_status(void)
{
    uint32_t s = 0;
    if (fs.float_exception_flags & float_flag_signaling) s |= FPSR_SNAN;
    if (fs.float_exception_flags & float_flag_invalid)   s |= FPSR_OPERR;
    if (fs.float_exception_flags & float_flag_divbyzero) s |= FPSR_DZ;
    if (fs.float_exception_flags & float_flag_overflow)  s |= FPSR_OVFL;
    if (fs.float_exception_flags & float_flag_underflow) s |= FPSR_UNFL;
    if (fs.float_exception_flags & float_flag_inexact)   s |= FPSR_INEX2;
    if (fs.float_exception_flags & float_flag_decimal)   s |= FPSR_INEX1;
    return s;
}

#pragma pack(push, 1)
struct Slot {
    uint8_t  op, prec, rmode, pad;
    uint16_t a_se; uint32_t a_hi, a_lo;
    uint16_t b_se; uint32_t b_hi, b_lo;
};
#pragma pack(pop)

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: fp_oracle ops.bin out.txt\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("ops"); return 2; }
    uint32_t n = 0;
    if (fread(&n, 4, 1, f) != 1) return 2;
    FILE *o = fopen(argv[2], "w");
    for (uint32_t i = 0; i < n; i++) {
        Slot s;
        if (fread(&s, sizeof(s), 1, f) != 1) break;
        memset(&fs, 0, sizeof(fs));
        set_mode(s.prec, s.rmode);
        fs.float_exception_flags = 0;
        floatx80 a, b, r;
        a.high = s.a_se; a.low = ((uint64_t)s.a_hi << 32) | s.a_lo;
        b.high = s.b_se; b.low = ((uint64_t)s.b_hi << 32) | s.b_lo;
        // The program computes FP0 = FP0 <op> A, having loaded FP0 with B.
        switch (s.op) {
            case 0: r = floatx80_add(b, a, &fs); break;
            case 1: r = floatx80_sub(b, a, &fs); break;
            case 2: r = floatx80_mul(b, a, &fs); break;
            case 3: r = floatx80_div(b, a, &fs); break;
            case 4: r = floatx80_sqrt(a, &fs);   break;
            case 5: r = floatx80_abs(a, &fs);    break;
            case 6: r = floatx80_neg(a, &fs);    break;
            case 7: r = floatx80_cmp(b, a, &fs); break;
            default: r = a; break;
        }
        fprintf(o, "%u %04X %08X %08X %08X\n", i, r.high,
                (uint32_t)(r.low >> 32), (uint32_t)(r.low & 0xFFFFFFFF),
                get_status());
    }
    fclose(f); fclose(o);
    return 0;
}
