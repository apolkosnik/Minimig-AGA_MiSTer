/* ioprobe - report the exact I/O probes behind XSysInfo's "Clock" and
   "Gary rev" lines, with addresses and returned values, so two cores can be
   compared rather than two summaries.

   GAYLEID ($DE1000) is not a plain register: a write resets a sequence
   counter and each read shifts out one bit (bit 7), so the identity depends
   on the SHAPE of the read strobes, not just on the data.  That is why it is
   worth capturing per-read values and not only the assembled byte.

   The RTC (MSM6242B) sits at $DC0000 with one nibble per longword-spaced
   register.  Absent hardware normally floats or reads back as $F.

   Build:  vc +aos68k -O1 -cpu=68040 -o ioprobe ioprobe.c
   Run from a CLI on each core with identical settings and ROM.        */
#include <stdio.h>

#define GAYLEID ((volatile unsigned char *)0x00DE1000)
#define RTCBASE ((volatile unsigned char *)0x00DC0000)

int main(void)
{
    unsigned char reads[8];
    unsigned char id = 0;
    int i;

    *GAYLEID = 0;                      /* reset the sequence counter */
    for (i = 0; i < 8; i++) {
        unsigned char v = *GAYLEID;
        reads[i] = v;
        id = (unsigned char)((id << 1) | ((v >> 7) & 1));
    }
    printf("GAYLEID $DE1000 reads:");
    for (i = 0; i < 8; i++) printf(" %02x", reads[i]);
    printf("\n  assembled id = %02x  (Gayle reports d0; a1200 ide expects d0)\n", id);

    printf("RTC $DC0000 nibbles:");
    for (i = 0; i < 16; i++) printf(" %x", RTCBASE[i * 4 + 3] & 0x0f);
    printf("\n");
    printf("  (a present MSM6242B counts; all f or all 0 means nothing answered)\n");
    return 0;
}
