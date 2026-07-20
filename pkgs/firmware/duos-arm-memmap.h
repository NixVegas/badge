/*
 * cvi_board_memmap.h for Milk-V Duo S (Sophgo SG2000, aarch64 boot)
 * 512 MB DDR3 at 0x80000000 (standard CV181x DRAM base).
 *
 * Values cross-checked against the Sophgo duo-buildroot-sdk-v2
 * build/boards/cv181x/sg2000_milkv_duos_glibc_arm64_sd/memmap.py.
 *
 * Layout summary (all values within DRAM 0x80000000..0x9FFFFFFF):
 *   0x80000000  DRAM base / BL31 (ATF monitor) load / run address
 *   0x80080000  OpenSBI / BL31 FDT  (MONITOR + 512 KB)
 *   0x81800000  FSBL decompression buffer  (16 MB, DRAM_BASE + 24 MB)
 *   0x9FE00000  C906L (small RISC-V core) firmware start (DRAM_BASE + DRAM_SIZE - 2 MB)
 *   0x9FFFFFFF  DRAM top (512 MB ceiling)
 */

#ifndef __CVI_BOARD_MEMMAP_H__
#define __CVI_BOARD_MEMMAP_H__

/* ------------------------------------------------------------------ */
/* Board DRAM parameters                                               */
/* ------------------------------------------------------------------ */
#define CVIMMAP_DRAM_BASE           0x80000000UL
#define CVIMMAP_DRAM_SIZE           0x20000000UL  /* 512 MB */

/* ------------------------------------------------------------------ */
/* BL31 (ATF secure monitor) run address                               */
/* ------------------------------------------------------------------ */
#define CVIMMAP_MONITOR_ADDR        0x80000000UL

/* ------------------------------------------------------------------ */
/* FDT passed to OpenSBI / BL31                                        */
/* ------------------------------------------------------------------ */
#define CVIMMAP_OPENSBI_FDT_ADDR    0x80080000UL

/* ------------------------------------------------------------------ */
/* FSBL decompression scratch area                                     */
/* Must be > DECOMP_ALLOC_SIZE (1 MB).  16 MB gives 15 MB buf.        */
/* ------------------------------------------------------------------ */
#define CVIMMAP_FSBL_UNZIP_ADDR     0x81800000UL
#define CVIMMAP_FSBL_UNZIP_SIZE     0x01000000UL  /* 16 MB */

/* ------------------------------------------------------------------ */
/* C906L (small RISC-V core) firmware start address in DRAM           */
/* ------------------------------------------------------------------ */
#define CVIMMAP_FSBL_C906L_START_ADDR  0x9FE00000UL

#endif /* __CVI_BOARD_MEMMAP_H__ */
