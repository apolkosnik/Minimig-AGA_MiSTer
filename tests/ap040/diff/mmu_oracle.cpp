// Reference 68040 table-walk results computed by WinUAE's OWN cpummu.cpp.
// Only the symbols cpummu.cpp needs are stubbed here; the walk itself is
// WinUAE's code, unmodified, so this is an oracle rather than a second
// implementation.  Same approach as fp_oracle.cpp with softfloat.
#include "sysconfig.h"
#include "sysdeps.h"
#include "options.h"
#include "memory.h"
#include "newcpu.h"
#include "cpummu.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

// ---- the machine the oracle walks -----------------------------------------
#define MEMSIZE 0x200000
static uae_u8 *omem;

struct regstruct regs;
struct uae_prefs currprefs, changed_prefs;
uae_u8 ce_banktype[65536], ce_cachable[65536];
int pissoff;

static uae_u32 o_get_long(uaecptr a)  { a &= (MEMSIZE-1);
    return (omem[a]<<24)|(omem[a+1]<<16)|(omem[a+2]<<8)|omem[a+3]; }
static void o_put_long(uaecptr a, uae_u32 v) { a &= (MEMSIZE-1);
    omem[a]=v>>24; omem[a+1]=v>>16; omem[a+2]=v>>8; omem[a+3]=v; }
static uae_u16 o_get_word(uaecptr a){ a &= (MEMSIZE-1); return (omem[a]<<8)|omem[a+1]; }
static void o_put_word(uaecptr a, uae_u32 v){ a &= (MEMSIZE-1); omem[a]=v>>8; omem[a+1]=v; }
static uae_u8 o_get_byte(uaecptr a) { return omem[a & (MEMSIZE-1)]; }
static void o_put_byte(uaecptr a, uae_u32 v){ omem[a & (MEMSIZE-1)] = v; }

uae_u32 (*x_phys_get_long)(uaecptr)  = o_get_long;
uae_u32 (*x_phys_get_word)(uaecptr)  = (uae_u32(*)(uaecptr))o_get_word;
uae_u32 (*x_phys_get_byte)(uaecptr)  = (uae_u32(*)(uaecptr))o_get_byte;
uae_u32 (*x_phys_get_ilong)(uaecptr) = o_get_long;
uae_u32 (*x_phys_get_iword)(uaecptr) = (uae_u32(*)(uaecptr))o_get_word;
void (*x_phys_put_long)(uaecptr, uae_u32) = o_put_long;
void (*x_phys_put_word)(uaecptr, uae_u32) = o_put_word;
void (*x_phys_put_byte)(uaecptr, uae_u32) = o_put_byte;

uae_u32 memory_get_long(uaecptr a){ return o_get_long(a); }
uae_u32 memory_get_word(uaecptr a){ return o_get_word(a); }
uae_u32 memory_get_byte(uaecptr a){ return o_get_byte(a); }
void memory_put_long(uaecptr a, uae_u32 v){ o_put_long(a,v); }
void memory_put_word(uaecptr a, uae_u32 v){ o_put_word(a,v); }
void memory_put_byte(uaecptr a, uae_u32 v){ o_put_byte(a,v); }
uae_u8 *memory_get_real_address(uaecptr a){ return omem + (a & (MEMSIZE-1)); }

uae_u32 get_long_cache_040(uaecptr a){ return o_get_long(a); }
uae_u32 get_word_cache_040(uaecptr a){ return o_get_word(a); }
uae_u32 get_byte_cache_040(uaecptr a){ return o_get_byte(a); }
uae_u32 get_long_icache040(uaecptr a){ return o_get_long(a); }
uae_u32 get_word_icache040(uaecptr a){ return o_get_word(a); }
void put_long_cache_040(uaecptr a, uae_u32 v){ o_put_long(a,v); }
void put_word_cache_040(uaecptr a, uae_u32 v){ o_put_word(a,v); }
void put_byte_cache_040(uaecptr a, uae_u32 v){ o_put_byte(a,v); }
uae_u32 mem_access_delay_long_read_c040(uaecptr a){ return o_get_long(a); }
uae_u32 mem_access_delay_word_read_c040(uaecptr a){ return o_get_word(a); }
uae_u32 mem_access_delay_byte_read_c040(uaecptr a){ return o_get_byte(a); }
void mem_access_delay_long_write_c040(uaecptr a, uae_u32 v){ o_put_long(a,v); }
void mem_access_delay_word_write_c040(uaecptr a, uae_u32 v){ o_put_word(a,v); }
void mem_access_delay_byte_write_c040(uaecptr a, uae_u32 v){ o_put_byte(a,v); }

uae_atomic atomic_or(volatile uae_atomic *p, uae_u32 v) { *p |= v; return *p; }
void write_log(const char *, ...) {}
void console_out_f(const char *, ...) {}
uae_u32 op_illg(uae_u32) { return 0; }


// ---- driver ----------------------------------------------------------------
// stdin protocol (text): urp srp tc, then one "probe <addr> <super> <data> <write>"
// per line.  Output: one result line per probe plus the modified table image.
int main(int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "usage: mmu_oracle mem.bin probes.txt out.txt\n"); return 2; }
    omem = (uae_u8 *)calloc(MEMSIZE, 1);
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("mem"); return 2; }
    fread(omem, 1, MEMSIZE, f);
    fclose(f);

    memset(&regs, 0, sizeof(regs));
    memset(&currprefs, 0, sizeof(currprefs));
    currprefs.mmu_model = 68040;
    currprefs.cpu_model = 68040;
    currprefs.mmu_ec = 0;

    FILE *p = fopen(argv[2], "r");
    FILE *o = fopen(argv[3], "w");
    char line[256];
    while (fgets(line, sizeof(line), p)) {
        unsigned urp, srp, tc, addr, super, data, write;
        if (sscanf(line, "cfg %x %x %x", &urp, &srp, &tc) == 3) {
            regs.urp = urp; regs.srp = srp; regs.tcr = tc;
            mmu_pagesize_8k = (tc & 0x4000) ? 1 : 0;
            mmu_set_tc(tc);
            mmu_flush_atc_all(true);
            continue;
        }
        if (sscanf(line, "probe %x %u %u %u", &addr, &super, &data, &write) == 4) {
            // Drive the PUBLIC PTEST path, which is what the RTL executes:
            // mmu_op_real walks the table and leaves the result in
            // regs.mmusr.  opcode $F548|regno = PTESTR, |0x20 = PTESTW.
            regs.regs[8 + 0] = addr;          // A0 holds the probed address
            regs.dfc = (data ? 1 : 2) | (super ? 4 : 0);
            regs.mmusr = 0;
            // PTEST opcode: (opcode & 0x0FD8) == 0x0548, and bit 5 SET
            // selects the READ probe (mmu_op_real: write = !(opcode & 32)).
            uae_u32 opcode = 0x0548 | (write ? 0x00 : 0x20);
            mmu_op_real(opcode, 0);
            fprintf(o, "%08x %08x\n", addr, regs.mmusr);
            continue;
        }
    }
    fclose(p);
    // modified table image back out, so U/M writebacks can be compared
    FILE *m = fopen("mmu_oracle_mem.bin", "wb");
    fwrite(omem, 1, MEMSIZE, m);
    fclose(m);
    fclose(o);
    return 0;
}
