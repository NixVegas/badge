/*
 * cvi_board_memmap.h for Milk-V Duo S (Sophgo SG2000, riscv64 U-Boot).
 * 512 MB DDR3 at 0x80000000.
 *
 * Values cross-referenced against Sophgo duo-buildroot-sdk-v2
 * build/boards/cv181x/sg2000_milkv_duos_musl_riscv64_sd/memmap.py.
 * The riscv and arm memory maps for the Duo S are identical at this level:
 * same DRAM base, same OpenSBI region, same U-Boot load address.
 *
 * This header is used by include/configs/cv181x-asic.h via
 * #include <cvi_board_memmap.h>. It must define all CVIMMAP_ macros
 * referenced in that file.
 */

#ifndef __CVI_BOARD_MEMMAP_H__
#define __CVI_BOARD_MEMMAP_H__

/* DRAM */
#define CVIMMAP_DRAM_BASE              0x80000000UL
#define CVIMMAP_DRAM_SIZE              0x20000000UL  /* 512 MB */

/* FDT passed by OpenSBI to U-Boot via prior_stage_fdt_address */
#define CVIMMAP_OPENSBI_FDT_ADDR       0x80080000UL

/* OpenSBI reserved region size (512 KB) */
#define CVIMMAP_OPENSBI_SIZE           0x80000UL

/* Kernel usable memory window (416 MB) */
#define CVIMMAP_KERNEL_MEMORY_ADDR     0x80000000UL
#define CVIMMAP_KERNEL_MEMORY_SIZE     0x1A600000UL

/* ION media memory (90 MB, after kernel window) */
#define CVIMMAP_ION_ADDR               0x9A600000UL
#define CVIMMAP_ION_SIZE               0x05A00000UL

/* Boot logo framebuffer (2 MB, above ION) */
#define CVIMMAP_BOOTLOGO_ADDR          0x9FA00000UL
#define CVIMMAP_BOOTLOGO_SIZE          0x00200000UL

/* U-Boot image load address */
#define CVIMMAP_UIMAG_ADDR             0x81000000UL

/* Initial stack pointer: UIMAG_ADDR + 16 MB scratch window */
#define CVIMMAP_CONFIG_SYS_INIT_SP_ADDR 0x82800000UL

/* FSBL decompression scratch */
#define CVIMMAP_FSBL_UNZIP_ADDR        0x81800000UL
#define CVIMMAP_FSBL_UNZIP_SIZE        0x01000000UL  /* 16 MB */

/* C906L small RISC-V core firmware start (not running during U-Boot init) */
#define CVIMMAP_FSBL_C906L_START_ADDR  0x9FE00000UL

#endif /* __CVI_BOARD_MEMMAP_H__ */
