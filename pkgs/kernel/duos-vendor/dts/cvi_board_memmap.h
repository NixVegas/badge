/*
 * Board memory map for the Milk-V Duo S (SG2000, 512MB DDR).
 * The vendor SDK generates this from build/boards/cv181x/
 * sg2000_milkv_duos_glibc_arm64_sd/memmap.py; computed here statically so the
 * vendor DTS chain (cv181x_default_memmap.dtsi) builds outside the SDK.
 *
 *   DRAM_BASE=0x80000000  DRAM_SIZE=512M
 *   FREERTOS: 2M at end of DRAM (0x9FE00000)
 *   KERNEL_MEMORY: DRAM minus FreeRTOS (0x80000000, 0x1FE00000)
 *   ION: 170M below FreeRTOS (0x95400000)
 *   FRAMEBUFFER/BOOTLOGO: 8000K below ION (0x94C30000)
 */
#ifndef __CVI_BOARD_MEMMAP_H__
#define __CVI_BOARD_MEMMAP_H__

#define CVIMMAP_KERNEL_MEMORY_ADDR		0x80000000
#define CVIMMAP_KERNEL_MEMORY_SIZE		0x1FE00000
#define CVIMMAP_MONITOR_ADDR			0x80000000
#define CVIMMAP_ATF_SIZE			0x80000
#define CVIMMAP_FREERTOS_ADDR			0x9FE00000
#define CVIMMAP_FREERTOS_SIZE			0x200000
#define CVIMMAP_FREERTOS_RESERVED_ION_SIZE	0x1600000
#define CVIMMAP_ION_SIZE			0xAA00000
#define CVIMMAP_FRAMEBUFFER_ADDR		0x94C30000
#define CVIMMAP_FRAMEBUFFER_SIZE		0x7D0000

#endif
