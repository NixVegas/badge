/*
 * drivers/mmc/host/sdhci-cv.c - CVITEK SDHCI Platform driver
 *
 * Copyright (c) 2013-2014, The Linux Foundation. All rights reserved.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 and
 * only version 2 as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 */

#include <linux/module.h>
#include <linux/delay.h>
#include <linux/mmc/mmc.h>
#include <linux/mmc/card.h>
#include <linux/mmc/host.h>
#include <linux/slab.h>
#include <linux/reset.h>
#include <linux/gpio.h>
#include <linux/device.h>
#include <linux/export.h>
#include <linux/io.h>
#include <linux/of_device.h>
#include <linux/platform_device.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/mmc/slot-gpio.h>
#include <linux/ktime.h>
#include <linux/clk.h>
#include <linux/sizes.h>
#include <linux/dma-mapping.h>
#include <linux/kernel.h>

/* card.h removed (procfs stats dropped) */
#include "sdhci-pltfm.h"
#include "sdhci-cv181x.h"

/* Sophgo added these to their patched sdhci core; define locally for the
 * mainline build. The PHASE_FORWARD quirks are never SET by this driver (only
 * tested), so any non-colliding bit works. ERR_INT_STATUS is the standard SD
 * Error Interrupt Status register (0x32), used only for a debug read. */
#ifndef SDHCI_QUIRK2_RX_PHASE_FORWARD
#define SDHCI_QUIRK2_RX_PHASE_FORWARD (1u << 28)
#endif
#ifndef SDHCI_QUIRK2_TX_PHASE_FORWARD
#define SDHCI_QUIRK2_TX_PHASE_FORWARD (1u << 29)
#endif
#ifndef SDHCI_ERR_INT_STATUS
#define SDHCI_ERR_INT_STATUS 0x32
#endif

#define DRIVER_NAME "cvi"
#define SDHCI_DUMP(f, x...) \
	pr_err("%s: " DRIVER_NAME ": " f, mmc_hostname(host->mmc), ## x)

#define MAX_CARD_TYPE 4
#define MAX_SPEED_MODE 5

#define CVI_PARENT "cvi"
#define CVI_STATS_PROC "cvi_info"
#define MAX_CLOCK_SCALE (4)

#define UNSTUFF_BITS(resp, start, size)                 \
	({                                                      \
	const int __size = size;                                \
	const u32 __mask = (__size < 32 ? 1 << __size : 0) - 1; \
	const int __off = 3 - ((start) / 32);                   \
	const int __shft = (start) & 31;                        \
	u32 __res;                                              \
	__res = resp[__off] >> __shft;                          \
	if (__size + __shft > 32)                               \
		__res |= resp[__off - 1] << ((32 - __shft) % 32);   \
	__res & __mask;                                         \
	})

#define BOUNDARY_OK(addr, len) \
	((addr | (SZ_128M - 1)) == ((addr + len - 1) | (SZ_128M - 1)))

static int cvi_proc_init(struct sdhci_cvi_host *cvi_host) { return 0; }
static int cvi_proc_shutdown(struct sdhci_cvi_host *cvi_host) { return 0; }

static void sdhci_cv181x_emmc_setup_pad(struct sdhci_host *host)
{
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);

	/* Name              Offset
	 * PAD_EMMC_RSTN     0x48
	 * PAD_EMMC_CLK      0x50
	 * PAD_EMMC_CMD      0x5C
	 * PAD_EMMC_DAT0     0x54
	 * PAD_EMMC_DAT1     0x60
	 * PAD_EMMC_DAT2     0x4C
	 * PAD_EMMC_DAT3     0x58

	 */

	u8 val = 0x0;

	writeb(val, cvi_host->pinmuxbase + 0x48);
	writeb(val, cvi_host->pinmuxbase + 0x50);
	writeb(val, cvi_host->pinmuxbase + 0x5C);
	writeb(val, cvi_host->pinmuxbase + 0x54);
	writeb(val, cvi_host->pinmuxbase + 0x60);
	writeb(val, cvi_host->pinmuxbase + 0x4C);
	writeb(val, cvi_host->pinmuxbase + 0x58);
}

static void sdhci_cv181x_sd_setup_pad(struct sdhci_host *host, bool bunplug)
{
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);

	/* Name              Offset unplug plug
	 * PAD_SDIO0_CD      0x34   SDIO0  SDIO0
	 * PAD_SDIO0_PWR_EN  0x38   SDIO0  SDIO0
	 * PAD_SDIO0_CLK     0x1C   XGPIO  SDIO0
	 * PAD_SDIO0_CMD     0x20   XGPIO  SDIO0
	 * PAD_SDIO0_D0      0x24   XGPIO  SDIO0
	 * PAD_SDIO0_D1      0x28   XGPIO  SDIO0
	 * PAD_SDIO0_D2      0x2C   XGPIO  SDIO0
	 * PAD_SDIO0_D3      0x30   XGPIO  SDIO0
	 * 0x0: SDIO0 function
	 * 0x3: XGPIO function
	 */

	u8 val = (bunplug) ? 0x3 : 0x0;

	if (0) /* CD stripped */
		writeb(0x3, cvi_host->pinmuxbase + 0x34);
	else
		writeb(0x0, cvi_host->pinmuxbase + 0x34);

	writeb(0x0, cvi_host->pinmuxbase + 0x38);
	writeb(val, cvi_host->pinmuxbase + 0x1C);
	writeb(val, cvi_host->pinmuxbase + 0x20);
	writeb(val, cvi_host->pinmuxbase + 0x24);
	writeb(val, cvi_host->pinmuxbase + 0x28);
	writeb(val, cvi_host->pinmuxbase + 0x2C);
	writeb(val, cvi_host->pinmuxbase + 0x30);
}

static void sdhci_cv181x_sd_setup_io(struct sdhci_host *host, bool reset)
{
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);

	/*
	 * Name              Offset reset sd0
	 * REG_SDIO0_CD      0x900  PU    PU
	 * REG_SDIO0_PWR_EN  0x904  PD    PD
	 * REG_SDIO0_CLK     0xA00  PD    PD
	 * REG_SDIO0_CMD     0xA04  PD    PU
	 * REG_SDIO0_D0      0xA08  PD    PU
	 * REG_SDIO0_D1      0xA0C  PD    PU
	 * REG_SDIO0_D2      0xA10  PD    PU
	 * REG_SDIO0_D3      0xA14  PD    PU
	 * BIT(2) : PU   enable(1)/disable(0)
	 * BIT(3) : PD   enable(1)/disable(0)
	 */

	u8 raise_bit = (reset) ?  BIT(3) : BIT(2);
	u8 down_bit  = (reset) ?  BIT(2) : BIT(3);

	writeb(((readb(cvi_host->pinmuxbase + 0x900) | BIT(2)) & ~(BIT(3))),
		cvi_host->pinmuxbase + 0x900);
	writeb(((readb(cvi_host->pinmuxbase + 0x904) | BIT(3)) & ~(BIT(2))),
		cvi_host->pinmuxbase + 0x904);
	writeb(((readb(cvi_host->pinmuxbase + 0xA00) | BIT(3)) & ~(BIT(2))),
		cvi_host->pinmuxbase + 0xA00);
	writeb(((readb(cvi_host->pinmuxbase + 0xA04) | raise_bit) & ~(down_bit)),
		cvi_host->pinmuxbase + 0xA04);
	writeb(((readb(cvi_host->pinmuxbase + 0xA08) | raise_bit) & ~(down_bit)),
		cvi_host->pinmuxbase + 0xA08);
	writeb(((readb(cvi_host->pinmuxbase + 0xA0C) | raise_bit) & ~(down_bit)),
		cvi_host->pinmuxbase + 0xA0C);
	writeb(((readb(cvi_host->pinmuxbase + 0xA10) | raise_bit) & ~(down_bit)),
		cvi_host->pinmuxbase + 0xA10);
	writeb(((readb(cvi_host->pinmuxbase + 0xA14) | raise_bit) & ~(down_bit)),
		cvi_host->pinmuxbase + 0xA14);
}

#ifdef CONFIG_ENABLE_EMMC_HW_RESET_QFN

#define GPIO_SWPORTA_DDR 0x004
#define GPIO_SWPORTA_DR 0x000
#define GPIO0_BASE 0x03020000
#define GPIO_NUM 19

static void sdhci_cvi_emmc_hw_reset(struct sdhci_host *host)
{
	pr_debug("%s use qfn\n", __func__);

	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);

	writeb(0x3, cvi_host->pinmuxbase + 0x64);
	pr_debug("qfn reset pinmux:%x\n", readb(cvi_host->pinmuxbase + 0x64));

	void __iomem *base = ioremap(GPIO0_BASE, 0x100);

	if (!base) {
		pr_err("ioremap failed for GPIO0_BASE\n");
		return;
	}

	void __iomem *dir_reg_base = base + GPIO_SWPORTA_DDR;
	void __iomem *val_reg_base = base + GPIO_SWPORTA_DR;

	uint32_t dir_reg = readl(dir_reg_base);
	uint32_t val_reg = readl(val_reg_base);

	/* Set direction to output */
	dir_reg &=  ~BIT(GPIO_NUM);
	dir_reg |= BIT(GPIO_NUM);
	writel(dir_reg, dir_reg_base);
	udelay(100);
	pr_debug("qfn reset 0, dir:%x, val:%x\n", readl(dir_reg_base), readl(val_reg_base));

	/* Set Value to 0, reset */
	val_reg	&=  ~BIT(GPIO_NUM);
	writel(val_reg, val_reg_base);
	udelay(500);
	pr_debug("qfn reset 1, dir:%x, val:%x\n", readl(dir_reg_base), readl(val_reg_base));

	/* Set value to 1 */
	val_reg	&=  ~BIT(GPIO_NUM);
	val_reg |= BIT(GPIO_NUM);
	writel(val_reg, val_reg_base);
	udelay(500);
	pr_debug("qfn reset 2, dir:%x, val:%x\n", readl(dir_reg_base), readl(val_reg_base));

 	iounmap(base);
}
#else
static void sdhci_cvi_emmc_hw_reset(struct sdhci_host *host)
{
	pr_debug("%s use bga\n", __func__);
	/*clear bit 8; pull down hw reset pin*/
	pr_debug("eMMC RST_n0: 0x%x\n", sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R));
	sdhci_writel(host,
		sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) & (~(BIT(8))),
		CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
	pr_debug("eMMC RST_n1: 0x%x\n", sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R));
	mdelay(1);
	/*set bit 8; pull up hw reset pin*/
	sdhci_writel(host,
		sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) | (BIT(8)),
		CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
	pr_debug("eMMC RST_n2: 0x%x\n", sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R));
	mdelay(1);
}
#endif

static void sdhci_cvi_reset_helper(struct sdhci_host *host, u8 mask)
{
	// disable Intr before reset
	sdhci_writel(host, 0, SDHCI_INT_ENABLE);
	sdhci_writel(host, 0, SDHCI_SIGNAL_ENABLE);

	sdhci_reset(host, mask);

	sdhci_writel(host, host->ier, SDHCI_INT_ENABLE);
	sdhci_writel(host, host->ier, SDHCI_SIGNAL_ENABLE);
}

static void reset_after_tuning_pass(struct sdhci_host *host)
{
	pr_debug("tuning pass\n");

	/* Clear BUF_RD_READY intr */
	sdhci_writew(host, sdhci_readw(host, SDHCI_INT_STATUS) & (~(0x1 << 5)),
		     SDHCI_INT_STATUS);

	/* Set SDHCI_SOFTWARE_RESET.SW_RST_DAT = 1 to clear buffered tuning block */
	sdhci_writeb(host, sdhci_readb(host, SDHCI_SOFTWARE_RESET) | (0x1 << 2), SDHCI_SOFTWARE_RESET);

	/* Set SDHCI_SOFTWARE_RESET.SW_RST_CMD = 1	*/
	sdhci_writeb(host, sdhci_readb(host, SDHCI_SOFTWARE_RESET) | (0x1 << 1), SDHCI_SOFTWARE_RESET);

	while (sdhci_readb(host, SDHCI_SOFTWARE_RESET) & 0x3)
		;
}

static inline uint32_t CHECK_MASK_BIT(void *_mask, uint32_t bit)
{
	uint32_t w = bit / 8;
	uint32_t off = bit % 8;

	return ((uint8_t *)_mask)[w] & (1 << off);
}

static inline void SET_MASK_BIT(void *_mask, uint32_t bit)
{
	uint32_t byte = bit / 8;
	uint32_t offset = bit % 8;
	((uint8_t *)_mask)[byte] |= (1 << offset);
}

static int sdhci_cv181x_general_select_drive_strength(struct sdhci_host *host,
		struct mmc_card *card, unsigned int max_dtr, int host_drv,
		int card_drv, int *drv_type)
{
	return MMC_SET_DRIVER_TYPE_A;
}

static void sdhci_cvi_general_set_uhs_signaling(struct sdhci_host *host, unsigned int uhs)
{
	struct mmc_host *mmc = host->mmc;
	u16 ctrl_2;

	ctrl_2 = sdhci_readw(host, SDHCI_HOST_CONTROL2);
	/* Select Bus Speed Mode for host */
	ctrl_2 &= ~SDHCI_CTRL_UHS_MASK;
	switch (uhs) {
	case MMC_TIMING_UHS_SDR12:
		ctrl_2 |= SDHCI_CTRL_UHS_SDR12;
		break;
	case MMC_TIMING_UHS_SDR25:
		ctrl_2 |= SDHCI_CTRL_UHS_SDR25;
		break;
	case MMC_TIMING_UHS_SDR50:
		ctrl_2 |= SDHCI_CTRL_UHS_SDR50;
		break;
	case MMC_TIMING_MMC_HS200:
	case MMC_TIMING_UHS_SDR104:
		ctrl_2 |= SDHCI_CTRL_UHS_SDR104;
		break;
	case MMC_TIMING_UHS_DDR50:
	case MMC_TIMING_MMC_DDR52:
		ctrl_2 |= SDHCI_CTRL_UHS_DDR50;
		break;
	}

	/*
	 * When clock frequency is less than 100MHz, the feedback clock must be
	 * provided and DLL must not be used so that tuning can be skipped. To
	 * provide feedback clock, the mode selection can be any value less
	 * than 3'b011 in bits [2:0] of HOST CONTROL2 register.
	 */
	if (host->clock <= 100000000 &&
	    (uhs == MMC_TIMING_MMC_HS400 ||
	     uhs == MMC_TIMING_MMC_HS200 ||
	     uhs == MMC_TIMING_UHS_SDR104))
		ctrl_2 &= ~SDHCI_CTRL_UHS_MASK;

	dev_dbg(mmc_dev(mmc), "%s: clock=%u uhs=%u ctrl_2=0x%x\n",
		mmc_hostname(host->mmc), host->clock, uhs, ctrl_2);
	sdhci_writew(host, ctrl_2, SDHCI_HOST_CONTROL2);
}

static unsigned int sdhci_cvi_general_get_max_clock(struct sdhci_host *host)
{
	pr_debug(DRIVER_NAME ":%s : %d\n", __func__, host->mmc->f_max);
	return host->mmc->f_max;
}

/* Used for wifi driver due if no SD card detect pin implemented */
static struct mmc_host *wifi_mmc;

int cvi_sdio_rescan(void)
{

	if (!wifi_mmc) {
		pr_err("invalid wifi mmc, please check the argument\n");
		return -EINVAL;
	}

	mmc_detect_change(wifi_mmc, 0);

	wifi_mmc->rescan_entered = 0;

	return 0;
}
EXPORT_SYMBOL_GPL(cvi_sdio_rescan);

// register sysfs
static ssize_t rescan_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t count)
{
	// mmc rescan
	cvi_sdio_rescan();

	return count;
}

static DEVICE_ATTR(rescan, 0200, NULL, rescan_store);

void sdhci_cvi_emmc_voltage_switch(struct sdhci_host *host)
{
}

static void sdhci_cvi_cv181x_set_tap(struct sdhci_host *host, unsigned int tap)
{
	pr_debug("%s %d\n", __func__, tap);
	// Set sd_clk_en(0x2c[2]) to 0
	sdhci_writew(host, sdhci_readw(host, SDHCI_CLOCK_CONTROL) & (~(0x1 << 2)), SDHCI_CLOCK_CONTROL);
	sdhci_writel(host,
		sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) & (~(BIT(1))),
		CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
	sdhci_writel(host, BIT(8) | tap << 16,
		     CVI_CV181X_SDHCI_PHY_TX_RX_DLY);
	sdhci_writel(host, 0, CVI_CV181X_SDHCI_PHY_CONFIG);
	// Set sd_clk_en(0x2c[2]) to 1
	sdhci_writew(host, sdhci_readw(host, SDHCI_CLOCK_CONTROL) | (0x1 << 2), SDHCI_CLOCK_CONTROL);
	mdelay(1);
}

static int sdhci_cv181x_general_execute_tuning(struct sdhci_host *host, u32 opcode)
{
	u16 min = 0;
	u32 k = 0;
	s32 ret;
	u32 retry_cnt = 0;

	u32 tuning_result[4] = {0, 0, 0, 0};
	u32 rx_lead_lag_result[4] = {0, 0, 0, 0};
	char tuning_graph[TUNE_MAX_PHCODE+1];
	char rx_lead_lag_graph[TUNE_MAX_PHCODE+1];

	u32 reg = 0;
	u32 reg_rx_lead_lag = 0;
	s32 max_lead_lag_idx = -1;
	s32 max_window_idx = -1;
	s32 cur_window_idx = -1;
	u16 max_lead_lag_size = 0;
	u16 max_window_size = 0;
	u16 cur_window_size = 0;
	s32 rx_lead_lag_phase = -1;
	s32 final_tap = -1;
	u32 rate = 0;

	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);

	reg = sdhci_readw(host, SDHCI_ERR_INT_STATUS);
	pr_debug("%s : SDHCI_ERR_INT_STATUS 0x%x\n", mmc_hostname(host->mmc),
		 reg);

	reg = sdhci_readw(host, SDHCI_HOST_CONTROL2);
	pr_debug("%s : host ctrl2 0x%x\n", mmc_hostname(host->mmc), reg);
	/* Set Host_CTRL2_R.SAMPLE_CLK_SEL=0 */
	sdhci_writew(host,
			 sdhci_readw(host, SDHCI_HOST_CONTROL2) & (~(0x1 << 7)),
			 SDHCI_HOST_CONTROL2);
	sdhci_writew(host,
			 sdhci_readw(host, SDHCI_HOST_CONTROL2) & (~(0x3 << 4)),
			 SDHCI_HOST_CONTROL2);

	reg = sdhci_readw(host, SDHCI_HOST_CONTROL2);
	pr_debug("%s : host ctrl2 0x%x\n", mmc_hostname(host->mmc), reg);

	while (min < TUNE_MAX_PHCODE) {
		retry_cnt = 0;
		sdhci_cvi_cv181x_set_tap(host, min);
		reg_rx_lead_lag = sdhci_readw(host, CVI_CV181X_SDHCI_PHY_DLY_STS) & BIT(1);

retry_tuning:
		ret = mmc_send_tuning(host->mmc, opcode, NULL);

		if (!ret && retry_cnt < MAX_TUNING_CMD_RETRY_COUNT) {
			retry_cnt++;
			goto retry_tuning;
		}

		if (ret) {
			SET_MASK_BIT(tuning_result, min);
		}

		if (reg_rx_lead_lag) {
			SET_MASK_BIT(rx_lead_lag_result, min);
		}

		min++;
	}

	reset_after_tuning_pass(host);

	pr_debug("tuning result:      0x%08x 0x%08x 0x%08x 0x%08x\n",
		tuning_result[0], tuning_result[1], tuning_result[2], tuning_result[3]);
	pr_debug("rx_lead_lag result: 0x%08x 0x%08x 0x%08x 0x%08x\n",
		rx_lead_lag_result[0], rx_lead_lag_result[1], rx_lead_lag_result[2], rx_lead_lag_result[3]);
	for (k = 0; k < TUNE_MAX_PHCODE; k++) {
		if (CHECK_MASK_BIT(tuning_result, k) == 0)
			tuning_graph[k] = '-';
		else
			tuning_graph[k] = 'x';
		if (CHECK_MASK_BIT(rx_lead_lag_result, k) == 0)
			rx_lead_lag_graph[k] = '0';
		else
			rx_lead_lag_graph[k] = '1';
	}
	tuning_graph[TUNE_MAX_PHCODE] = '\0';
	rx_lead_lag_graph[TUNE_MAX_PHCODE] = '\0';

	pr_debug("tuning graph:      %s\n", tuning_graph);
	pr_debug("rx_lead_lag graph: %s\n", rx_lead_lag_graph);

	// Find a final tap as median of maximum window
	for (k = 0; k < TUNE_MAX_PHCODE; k++) {
		if (CHECK_MASK_BIT(tuning_result, k) == 0) {
			if (-1 == cur_window_idx) {
				cur_window_idx = k;
			}
			cur_window_size++;

			if (cur_window_size > max_window_size) {
				max_window_size = cur_window_size;
				max_window_idx = cur_window_idx;
				if (max_window_size >= TAP_WINDOW_THLD)
					final_tap = cur_window_idx + (max_window_size/2);
			}
		} else {
			cur_window_idx = -1;
			cur_window_size = 0;
		}
	}

	cur_window_idx = -1;
	cur_window_size = 0;
	for (k = 0; k < TUNE_MAX_PHCODE; k++) {
		if (CHECK_MASK_BIT(rx_lead_lag_result, k) == 0) {
			//from 1 to 0 and window_size already computed.
			if ((rx_lead_lag_phase == 1) && (cur_window_size > 0)) {
				max_lead_lag_idx = cur_window_idx;
				max_lead_lag_size = cur_window_size;
				break;
			}
			if (cur_window_idx == -1) {
				cur_window_idx = k;
			}
			cur_window_size++;
			rx_lead_lag_phase = 0;
		} else {
			rx_lead_lag_phase = 1;
			if ((cur_window_idx != -1) && (cur_window_size > 0)) {
				cur_window_size++;
				max_lead_lag_idx = cur_window_idx;
				max_lead_lag_size = cur_window_size;
			} else {
				cur_window_size = 0;
			}
		}
	}
	rate = max_window_size * 100 / max_lead_lag_size;
	pr_debug("MaxWindow[Idx, Width]:[%d,%u] Tuning Tap: %d\n", max_window_idx, max_window_size, final_tap);
	pr_debug("RX_LeadLag[Idx, Width]:[%d,%u] rate = %d\n", max_lead_lag_idx, max_lead_lag_size, rate);

	sdhci_cvi_cv181x_set_tap(host, final_tap);
	cvi_host->final_tap = final_tap;
	pr_debug("%s finished tuning, code:%d\n", __func__, final_tap);

	return mmc_send_tuning(host->mmc, opcode, NULL);
}

static void sdhci_cv181x_emmc_reset(struct sdhci_host *host, u8 mask)
{
	u16 ctrl_2;
	u32 phy_rx_tx_dly_reg = 0;
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);

	pr_debug("%s mask = 0x%x\n", __func__, mask);
	sdhci_cvi_reset_helper(host, mask);

	//reg_0x200[0] = 1 for mmc
	sdhci_writel(host,
			 sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) | BIT(0),
			 CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);

	ctrl_2 = sdhci_readw(host, SDHCI_HOST_CONTROL2);
	ctrl_2 &= SDHCI_CTRL_UHS_MASK;
	if (ctrl_2 == SDHCI_CTRL_UHS_SDR104) {
		//reg_0x200[1] = 0
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) & ~(BIT(1)),
			CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
		//reg_0x24c[0] = 0
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_PHY_CONFIG) & ~(BIT(0)),
			CVI_CV181X_SDHCI_PHY_CONFIG);
		//reg_0x240[22:16] = tap reg_0x240[9:8] = 1 reg_0x240[6:0] = 0
		sdhci_writel(host,
			(BIT(8) | ((cvi_host->final_tap & 0x7F) << 16)),
			CVI_CV181X_SDHCI_PHY_TX_RX_DLY);
	} else {
		//Reset as DS/HS setting.
		//reg_0x200[1] = 1
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) | BIT(1),
			CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
		//reg_0x24c[0] = 1
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_PHY_CONFIG) | BIT(0),
			CVI_CV181X_SDHCI_PHY_CONFIG);
		//reg_0x240[25:24] = 00'b/01'b; reg_0x240[22:16] = 0
		//reg_0x240[9:8] = 00'b/01'b reg_0x240[6:0] = 0
		if (!(host->quirks2 & SDHCI_QUIRK2_RX_PHASE_FORWARD))
			phy_rx_tx_dly_reg |= BIT(24);
		if (!(host->quirks2 & SDHCI_QUIRK2_TX_PHASE_FORWARD))
			phy_rx_tx_dly_reg |= BIT(8);
		sdhci_writel(host, phy_rx_tx_dly_reg, CVI_CV181X_SDHCI_PHY_TX_RX_DLY);
	}
}

static void sdhci_cv181x_sd_reset(struct sdhci_host *host, u8 mask)
{
	u16 ctrl_2;
	u32 phy_rx_tx_dly_reg = 0;
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);

	pr_debug("%s mask = 0x%x\n", __func__, mask);
	sdhci_cvi_reset_helper(host, mask);

	ctrl_2 = sdhci_readw(host, SDHCI_HOST_CONTROL2);
	ctrl_2 &= SDHCI_CTRL_UHS_MASK;
	if (ctrl_2 == SDHCI_CTRL_UHS_SDR104) {
		//reg_0x200[1] = 0
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) & ~(BIT(1)),
			CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
		//reg_0x24c[0] = 0
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_PHY_CONFIG) & ~(BIT(0)),
			CVI_CV181X_SDHCI_PHY_CONFIG);
		//reg_0x240[22:16] = tap reg_0x240[9:8] = 1 reg_0x240[6:0] = 0
		sdhci_writel(host,
			(BIT(8) | ((cvi_host->final_tap & 0x7F) << 16)),
			CVI_CV181X_SDHCI_PHY_TX_RX_DLY);
	} else {
		//Reset as DS/HS setting.
		//reg_0x200[1] = 1
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) | BIT(1),
			CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
		//reg_0x24c[0] = 1
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_PHY_CONFIG) | BIT(0),
			CVI_CV181X_SDHCI_PHY_CONFIG);
		//reg_0x240[25:24] = 00'b/01'b; reg_0x240[22:16] = 0
		//reg_0x240[9:8] = 00'b/01'b reg_0x240[6:0] = 0
		if (!(host->quirks2 & SDHCI_QUIRK2_RX_PHASE_FORWARD))
			phy_rx_tx_dly_reg |= BIT(24);
		if (!(host->quirks2 & SDHCI_QUIRK2_TX_PHASE_FORWARD))
			phy_rx_tx_dly_reg |= BIT(8);
		sdhci_writel(host, phy_rx_tx_dly_reg, CVI_CV181X_SDHCI_PHY_TX_RX_DLY);
	}
}

static void sdhci_cv181x_sdio_reset(struct sdhci_host *host, u8 mask)
{
	u16 ctrl_2;
	u32 phy_rx_tx_dly_reg = 0;
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);

	pr_debug("%s mask = 0x%x\n", __func__, mask);
	sdhci_cvi_reset_helper(host, mask);

	ctrl_2 = sdhci_readw(host, SDHCI_HOST_CONTROL2);
	ctrl_2 &= SDHCI_CTRL_UHS_MASK;
	if (ctrl_2 == SDHCI_CTRL_UHS_SDR104) {
		//reg_0x200[1] = 0
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) & ~(BIT(1)),
			CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
		//reg_0x200[16] = 1 for sd1
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) | BIT(16),
			CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
		//reg_0x24c[0] = 0
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_PHY_CONFIG) & ~(BIT(0)),
			CVI_CV181X_SDHCI_PHY_CONFIG);
		//reg_0x240[22:16] = tap reg_0x240[9:8] = 1 reg_0x240[6:0] = 0
		sdhci_writel(host,
			(BIT(8) | ((cvi_host->final_tap & 0x7F) << 16)),
			CVI_CV181X_SDHCI_PHY_TX_RX_DLY);
	} else {
		//Reset as DS/HS setting.
		//reg_0x200[1] = 1
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) | BIT(1),
			CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
		//reg_0x200[16] = 1 for sd1
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) | BIT(16),
			CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
		//reg_0x24c[0] = 1
		sdhci_writel(host,
			sdhci_readl(host, CVI_CV181X_SDHCI_PHY_CONFIG) | BIT(0),
			CVI_CV181X_SDHCI_PHY_CONFIG);
		//reg_0x240[25:24] = 00'b/01'b; reg_0x240[22:16] = 0
		//reg_0x240[9:8] = 00'b/01'b reg_0x240[6:0] = 0
		if (!(host->quirks2 & SDHCI_QUIRK2_RX_PHASE_FORWARD))
			phy_rx_tx_dly_reg |= BIT(24);
		if (!(host->quirks2 & SDHCI_QUIRK2_TX_PHASE_FORWARD))
			phy_rx_tx_dly_reg |= BIT(8);
		sdhci_writel(host, phy_rx_tx_dly_reg, CVI_CV181X_SDHCI_PHY_TX_RX_DLY);
	}
}

void sdhci_cv181x_sd_voltage_switch(struct sdhci_host *host)
{
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);

	pr_debug("%s\n", __func__);

	// enable SDIO0_CLK[7:5] to set CLK max strengh
	writeb((readb(cvi_host->pinmuxbase + 0xA00) | BIT(7) | BIT(6) | BIT(5)),
		cvi_host->pinmuxbase + 0xA00);

	//Voltage switching flow (1.8v)
	//reg_pwrsw_auto=1, reg_pwrsw_disc=0, pwrsw_vsel=1(1.8v), reg_en_pwrsw=1
	writel(0xB | (readl(cvi_host->topbase + OFFSET_SD_PWRSW_CTRL) & 0xFFFFFFF0),
		cvi_host->topbase + OFFSET_SD_PWRSW_CTRL);
	pr_debug("sd PWRSW 0x%x\n", readl(cvi_host->topbase + OFFSET_SD_PWRSW_CTRL));
	cvi_host->sdio0_voltage_1_8_v = 1;

	mdelay(1);
}

void sdhci_cv181x_sd_voltage_restore(struct sdhci_host *host, bool bunplug)
{
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);

	pr_debug("%s\n", __func__);

	if (bunplug) {
		//Voltage close flow
		//(reg_pwrsw_auto=1, reg_pwrsw_disc=1, reg_pwrsw_vsel=1(1.8v), reg_en_pwrsw=0)
		writel(0xE | (readl(cvi_host->topbase + OFFSET_SD_PWRSW_CTRL) & 0xFFFFFFF0),
			cvi_host->topbase + OFFSET_SD_PWRSW_CTRL);
		cvi_host->sdio0_voltage_1_8_v = 0;
	} else {
		if (!cvi_host->sdio0_voltage_1_8_v) {
			//Voltage switching flow (3.3)
			//(reg_pwrsw_auto=1, reg_pwrsw_disc=0, reg_pwrsw_vsel=0(3.0v), reg_en_pwrsw=1)
			writel(0x9 | (readl(cvi_host->topbase + OFFSET_SD_PWRSW_CTRL) & 0xFFFFFFF0),
				cvi_host->topbase + OFFSET_SD_PWRSW_CTRL);
		}
	}

	//wait 1ms
	mdelay(1);

	// restore to DS/HS setting
	sdhci_writel(host,
		sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R) | BIT(1) | BIT(8) | BIT(9),
		CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R);
	sdhci_writel(host, 0x1000100, CVI_CV181X_SDHCI_PHY_TX_RX_DLY);
	sdhci_writel(host, 1, CVI_CV181X_SDHCI_PHY_CONFIG);

	mdelay(1);
}

static void sdhci_cv181x_sd_set_power(struct sdhci_host *host, unsigned char mode,
				unsigned short vdd)
{
	struct mmc_host *mmc = host->mmc;

	pr_debug("%s:mode %u, vdd %u\n", __func__, mode, vdd);

	if (mode == MMC_POWER_ON && mmc->ops->get_cd(mmc)) {
		sdhci_set_power_noreg(host, mode, vdd);
		sdhci_cv181x_sd_voltage_restore(host, false);
		sdhci_cv181x_sd_setup_pad(host, false);
		sdhci_cv181x_sd_setup_io(host, false);
		mdelay(5);
	} else if (mode == MMC_POWER_OFF) {
		sdhci_cv181x_sd_setup_pad(host, true);
		sdhci_cv181x_sd_setup_io(host, true);
		sdhci_cv181x_sd_voltage_restore(host, true);
		sdhci_set_power_noreg(host, mode, vdd);
		mdelay(30);
	}
}

static void sdhci_cv181x_emmc_dump_vendor_regs(struct sdhci_host *host)
{
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);
	u8 clk_source_select = 0;
	u8 PAD_EMMC_RSTN = 0;
	u8 PAD_EMMC_CLK  = 0;
	u8 PAD_EMMC_CMD  = 0;
	u8 PAD_EMMC_DAT0 = 0;
	u8 PAD_EMMC_DAT1 = 0;
	u8 PAD_EMMC_DAT2 = 0;
	u8 PAD_EMMC_DAT3 = 0;
	u8 REG_EMMC_RSTN = 0;
	u8 REG_EMMC_CLK  = 0;
	u8 REG_EMMC_CMD  = 0;
	u8 REG_EMMC_DAT0 = 0;
	u8 REG_EMMC_DAT1 = 0;
	u8 REG_EMMC_DAT2 = 0;
	u8 REG_EMMC_DAT3 = 0;

	SDHCI_DUMP(": Reg_200:   0x%08x | Reg_240:  0x%08x\n",
		   sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R),
		   sdhci_readl(host, CVI_CV181X_SDHCI_PHY_TX_RX_DLY));
	SDHCI_DUMP(": Reg_244:   0x%08x | Reg_248:  0x%08x\n",
		   sdhci_readl(host, CVI_CV181X_SDHCI_PHY_DS_DLY),
		   sdhci_readw(host, CVI_CV181X_SDHCI_PHY_DLY_STS));
	SDHCI_DUMP(": Reg_24C:   0x%08x\n",
		   sdhci_readl(host, CVI_CV181X_SDHCI_PHY_CONFIG));

	PAD_EMMC_RSTN = readb(cvi_host->pinmuxbase + 0x48) & 0x07;
	PAD_EMMC_CLK  = readb(cvi_host->pinmuxbase + 0x50) & 0x07;
	PAD_EMMC_CMD  = readb(cvi_host->pinmuxbase + 0x5C) & 0x07;
	PAD_EMMC_DAT0 = readb(cvi_host->pinmuxbase + 0x54) & 0x07;
	PAD_EMMC_DAT1 = readb(cvi_host->pinmuxbase + 0x60) & 0x07;
	PAD_EMMC_DAT2 = readb(cvi_host->pinmuxbase + 0x4C) & 0x07;
	PAD_EMMC_DAT3 = readb(cvi_host->pinmuxbase + 0x58) & 0x07;
	REG_EMMC_RSTN = readb(cvi_host->pinmuxbase + 0x914);
	REG_EMMC_CLK  = readb(cvi_host->pinmuxbase + 0x91D);
	REG_EMMC_CMD  = readb(cvi_host->pinmuxbase + 0x928);
	REG_EMMC_DAT0 = readb(cvi_host->pinmuxbase + 0x920);
	REG_EMMC_DAT1 = readb(cvi_host->pinmuxbase + 0x92D);
	REG_EMMC_DAT2 = readb(cvi_host->pinmuxbase + 0x918);
	REG_EMMC_DAT3 = readb(cvi_host->pinmuxbase + 0x924);

	SDHCI_DUMP(": PAD_EMMC_RSTN:0x%02x PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_EMMC_RSTN, (REG_EMMC_RSTN & 0x04)>>2, (REG_EMMC_RSTN & 0x08)>>3,
		(REG_EMMC_RSTN & 0x80)>>7, (REG_EMMC_RSTN & 0x40)>>6, (REG_EMMC_RSTN & 0x20)>>5);
	SDHCI_DUMP(": PAD_EMMC_CLK:0x%02x  PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_EMMC_CLK, (REG_EMMC_CLK & 0x04)>>2, (REG_EMMC_CLK & 0x08)>>3,
		(REG_EMMC_CLK & 0x80)>>7, (REG_EMMC_CLK & 0x40)>>6, (REG_EMMC_CLK & 0x20)>>5);
	SDHCI_DUMP(": PAD_EMMC_CMD:0x%02x  PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_EMMC_CMD, (REG_EMMC_CMD & 0x04)>>2, (REG_EMMC_CMD & 0x08)>>3,
		(REG_EMMC_CMD & 0x80)>>7, (REG_EMMC_CMD & 0x40)>>6, (REG_EMMC_CMD & 0x20)>>5);
	SDHCI_DUMP(": PAD_EMMC_DAT0:0x%02x PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_EMMC_DAT0, (REG_EMMC_DAT0 & 0x04)>>2, (REG_EMMC_DAT0 & 0x08)>>3,
		(REG_EMMC_DAT0 & 0x80)>>7, (REG_EMMC_DAT0 & 0x40)>>6, (REG_EMMC_DAT0 & 0x20)>>5);
	SDHCI_DUMP(": PAD_EMMC_DAT1:0x%02x PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_EMMC_DAT1, (REG_EMMC_DAT1 & 0x04)>>2, (REG_EMMC_DAT1 & 0x08)>>3,
		(REG_EMMC_DAT1 & 0x80)>>7, (REG_EMMC_DAT1 & 0x40)>>6, (REG_EMMC_DAT1 & 0x20)>>5);
	SDHCI_DUMP(": PAD_EMMC_DAT2:0x%02x PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_EMMC_DAT2, (REG_EMMC_DAT2 & 0x04)>>2, (REG_EMMC_DAT2 & 0x08)>>3,
		(REG_EMMC_DAT2 & 0x80)>>7, (REG_EMMC_DAT2 & 0x40)>>6, (REG_EMMC_DAT2 & 0x20)>>5);
	SDHCI_DUMP(": PAD_EMMC_DAT3:0x%02x PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_EMMC_DAT3, (REG_EMMC_DAT3 & 0x04)>>2, (REG_EMMC_DAT3 & 0x08)>>3,
		(REG_EMMC_DAT3 & 0x80)>>7, (REG_EMMC_DAT3 & 0x40)>>6, (REG_EMMC_DAT3 & 0x20)>>5);

	clk_source_select = (readb(cvi_host->clkgenbase + 0x20) & 0x20) >> 5;

	SDHCI_DUMP(": clk_emmc enable[16]:0x%08x\n", readl(cvi_host->clkgenbase));
	SDHCI_DUMP(": clk_emmc source_select:%u\n", clk_source_select);
	if (clk_source_select == 0) {
		SDHCI_DUMP(": clk_emmc REG:0x03002068 = 0x%08x\n",
		readl(cvi_host->clkgenbase + 0x68));
		if (readl(cvi_host->clkgenbase + 0x68) == 0x00000001)
			SDHCI_DUMP(": clk_emmc %d MHz\n", DISPPLL_MHZ/12);
	} else if (clk_source_select == 1) {
		SDHCI_DUMP(": clk_emmc REG:0x03002064 = 0x%08x\n",
		readl(cvi_host->clkgenbase + 0x64));
		if (readl(cvi_host->clkgenbase + 0x64) == 0x00040009)
			SDHCI_DUMP(": clk_emmc %d MHz\n", FPLL_MHZ/4);
	}
}

static void sdhci_cv181x_sd_dump_vendor_regs(struct sdhci_host *host)
{
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);
	u8 clk_source_select = 0;
	u8 PAD_SDIO0_PWR_EN = 0;
	u8 PAD_SDIO0_CD  = 0;
	u8 PAD_SDIO0_CLK = 0;
	u8 PAD_SDIO0_CMD = 0;
	u8 PAD_SDIO0_D0  = 0;
	u8 PAD_SDIO0_D1  = 0;
	u8 PAD_SDIO0_D2  = 0;
	u8 PAD_SDIO0_D3  = 0;
	u8 REG_SDIO0_PWR_EN = 0;
	u8 REG_SDIO0_CD  = 0;
	u8 REG_SDIO0_CLK = 0;
	u8 REG_SDIO0_CMD = 0;
	u8 REG_SDIO0_D0  = 0;
	u8 REG_SDIO0_D1  = 0;
	u8 REG_SDIO0_D2  = 0;
	u8 REG_SDIO0_D3  = 0;

	SDHCI_DUMP(": Reg_200:   0x%08x | Reg_240:  0x%08x\n",
		   sdhci_readl(host, CVI_CV181X_SDHCI_VENDOR_MSHC_CTRL_R),
		   sdhci_readl(host, CVI_CV181X_SDHCI_PHY_TX_RX_DLY));
	SDHCI_DUMP(": Reg_244:   0x%08x | Reg_248:  0x%08x\n",
		   sdhci_readl(host, CVI_CV181X_SDHCI_PHY_DS_DLY),
		   sdhci_readw(host, CVI_CV181X_SDHCI_PHY_DLY_STS));
	SDHCI_DUMP(": Reg_24C:   0x%08x | unplugg:  0x%08x\n",
		   sdhci_readl(host, CVI_CV181X_SDHCI_PHY_CONFIG),
		   0 /* ever_unplugged n/a */);

	PAD_SDIO0_PWR_EN = readb(cvi_host->pinmuxbase + 0x38) & 0x07;
	PAD_SDIO0_CD  = readb(cvi_host->pinmuxbase + 0x34) & 0x07;
	PAD_SDIO0_CLK = readb(cvi_host->pinmuxbase + 0x1C) & 0x07;
	PAD_SDIO0_CMD = readb(cvi_host->pinmuxbase + 0x20) & 0x07;
	PAD_SDIO0_D0  = readb(cvi_host->pinmuxbase + 0x24) & 0x07;
	PAD_SDIO0_D1  = readb(cvi_host->pinmuxbase + 0x28) & 0x07;
	PAD_SDIO0_D2  = readb(cvi_host->pinmuxbase + 0x2C) & 0x07;
	PAD_SDIO0_D3  = readb(cvi_host->pinmuxbase + 0x30) & 0x07;
	REG_SDIO0_PWR_EN = readb(cvi_host->pinmuxbase + 0x904);
	REG_SDIO0_CD  = readb(cvi_host->pinmuxbase + 0x900);
	REG_SDIO0_CLK = readb(cvi_host->pinmuxbase + 0xA00);
	REG_SDIO0_CMD = readb(cvi_host->pinmuxbase + 0xA04);
	REG_SDIO0_D0  = readb(cvi_host->pinmuxbase + 0xA08);
	REG_SDIO0_D1  = readb(cvi_host->pinmuxbase + 0xA0C);
	REG_SDIO0_D2  = readb(cvi_host->pinmuxbase + 0xA10);
	REG_SDIO0_D3  = readb(cvi_host->pinmuxbase + 0xA14);

	SDHCI_DUMP(": PAD_SDIO0_PWR_EN:0x%02x PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_SDIO0_PWR_EN, (REG_SDIO0_PWR_EN & 0x04)>>2, (REG_SDIO0_PWR_EN & 0x08)>>3,
		(REG_SDIO0_PWR_EN & 0x80)>>7, (REG_SDIO0_PWR_EN & 0x40)>>6, (REG_SDIO0_PWR_EN & 0x20)>>5);
	SDHCI_DUMP(": PAD_SDIO0_CD:0x%02x  PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_SDIO0_CD, (REG_SDIO0_CD & 0x04)>>2, (REG_SDIO0_CD & 0x08)>>3,
		(REG_SDIO0_CD & 0x80)>>7, (REG_SDIO0_CD & 0x40)>>6, (REG_SDIO0_CD & 0x20)>>5);
	SDHCI_DUMP(": PAD_SDIO0_CLK:0x%02x PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_SDIO0_CLK, (REG_SDIO0_CLK & 0x04)>>2, (REG_SDIO0_CLK & 0x08)>>3,
		(REG_SDIO0_CLK & 0x80)>>7, (REG_SDIO0_CLK & 0x40)>>6, (REG_SDIO0_CLK & 0x20)>>5);
	SDHCI_DUMP(": PAD_SDIO0_CMD:0x%02x PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_SDIO0_CMD, (REG_SDIO0_CMD & 0x04)>>2, (REG_SDIO0_CMD & 0x08)>>3,
		(REG_SDIO0_CMD & 0x80)>>7, (REG_SDIO0_CMD & 0x40)>>6, (REG_SDIO0_CMD & 0x20)>>5);
	SDHCI_DUMP(": PAD_SDIO0_D0:0x%02x  PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_SDIO0_D0, (REG_SDIO0_D0 & 0x04)>>2, (REG_SDIO0_D0 & 0x08)>>3,
		(REG_SDIO0_D0 & 0x80)>>7, (REG_SDIO0_D0 & 0x40)>>6, (REG_SDIO0_D0 & 0x20)>>5);
	SDHCI_DUMP(": PAD_SDIO0_D1:0x%02x  PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_SDIO0_D1, (REG_SDIO0_D1 & 0x04)>>2, (REG_SDIO0_D1 & 0x08)>>3,
		(REG_SDIO0_D1 & 0x80)>>7, (REG_SDIO0_D1 & 0x40)>>6, (REG_SDIO0_D1 & 0x20)>>5);
	SDHCI_DUMP(": PAD_SDIO0_D2:0x%02x  PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_SDIO0_D2, (REG_SDIO0_D2 & 0x04)>>2, (REG_SDIO0_D2 & 0x08)>>3,
		(REG_SDIO0_D2 & 0x80)>>7, (REG_SDIO0_D2 & 0x40)>>6, (REG_SDIO0_D2 & 0x20)>>5);
	SDHCI_DUMP(": PAD_SDIO0_D3:0x%02x  PU:%u PD:%u DS[2:0]:%u%u%u\n",
		PAD_SDIO0_D3, (REG_SDIO0_D3 & 0x04)>>2, (REG_SDIO0_D3 & 0x08)>>3,
		(REG_SDIO0_D3 & 0x80)>>7, (REG_SDIO0_D3 & 0x40)>>6, (REG_SDIO0_D3 & 0x20)>>5);

	clk_source_select = (readb(cvi_host->clkgenbase + 0x20) & 0x40) >> 6;

	SDHCI_DUMP(": clk_sd0 enable[19]:0x%08x\n", readl(cvi_host->clkgenbase));
	SDHCI_DUMP(": clk_sd0 source_select:%u\n", clk_source_select);
	if (clk_source_select == 0) {
		SDHCI_DUMP(": clk_sd0 REG:0x03002074 = 0x%08x\n",
		readl(cvi_host->clkgenbase + 0x74));
		if (readl(cvi_host->clkgenbase + 0x74) == 0x00000001)
			SDHCI_DUMP(": clk_sd0 %d MHz\n", DISPPLL_MHZ/12);
	} else if (clk_source_select == 1) {
		SDHCI_DUMP(": clk_sd0 REG:0x03002070 = 0x%08x\n",
		readl(cvi_host->clkgenbase + 0x70));
		if (readl(cvi_host->clkgenbase + 0x70) == 0x00040009)
			SDHCI_DUMP(": clk_sd0 %d MHz\n", FPLL_MHZ/4);
	}
}

static void cvi_adma_write_desc(struct sdhci_host *host, void **desc,
		dma_addr_t addr, int len, unsigned int cmd)
{
	int tmplen, offset;

	if (likely(!len || BOUNDARY_OK(addr, len))) {
		sdhci_adma_write_desc(host, desc, addr, len, cmd);
		return;
	}

	offset = addr & (SZ_128M - 1);
	tmplen = SZ_128M - offset;
	sdhci_adma_write_desc(host, desc, addr, tmplen, cmd);

	addr += tmplen;
	len -= tmplen;
	sdhci_adma_write_desc(host, desc, addr, len, cmd);
}

static const struct sdhci_ops sdhci_cv181x_emmc_ops = {
	.reset = sdhci_cv181x_emmc_reset,
	.hw_reset = sdhci_cvi_emmc_hw_reset,
	.set_clock = sdhci_set_clock,
	.set_bus_width = sdhci_set_bus_width,
	.get_max_clock = sdhci_cvi_general_get_max_clock,
	.voltage_switch = sdhci_cvi_emmc_voltage_switch,
	.set_uhs_signaling = sdhci_cvi_general_set_uhs_signaling,
	.platform_execute_tuning = sdhci_cv181x_general_execute_tuning,
	.dump_vendor_regs = sdhci_cv181x_emmc_dump_vendor_regs,
	.adma_write_desc = cvi_adma_write_desc,
};

static const struct sdhci_ops sdhci_cv181x_sd_ops = {
	.reset = sdhci_cv181x_sd_reset,
	.set_clock = sdhci_set_clock,
	.set_power = sdhci_cv181x_sd_set_power,
	.set_bus_width = sdhci_set_bus_width,
	.get_max_clock = sdhci_cvi_general_get_max_clock,
	.voltage_switch = sdhci_cv181x_sd_voltage_switch,
	.set_uhs_signaling = sdhci_cvi_general_set_uhs_signaling,
	.platform_execute_tuning = sdhci_cv181x_general_execute_tuning,
	.dump_vendor_regs = sdhci_cv181x_sd_dump_vendor_regs,
	.adma_write_desc = cvi_adma_write_desc,
};

static const struct sdhci_ops sdhci_cv181x_sdio_ops = {
	.reset = sdhci_cv181x_sdio_reset,
	.set_clock = sdhci_set_clock,
	.set_bus_width = sdhci_set_bus_width,
	.get_max_clock = sdhci_cvi_general_get_max_clock,
	.voltage_switch = sdhci_cv181x_sd_voltage_switch,
	.set_uhs_signaling = sdhci_cvi_general_set_uhs_signaling,
	.platform_execute_tuning = sdhci_cv181x_general_execute_tuning,
	.adma_write_desc = cvi_adma_write_desc,
};

static const struct sdhci_ops sdhci_cv181x_fpga_emmc_ops = {
	.reset = sdhci_cv181x_sd_reset,
	.set_clock = sdhci_set_clock,
	.set_bus_width = sdhci_set_bus_width,
	.get_max_clock = sdhci_cvi_general_get_max_clock,
	.voltage_switch = sdhci_cvi_emmc_voltage_switch,
	.set_uhs_signaling = sdhci_cvi_general_set_uhs_signaling,
	.platform_execute_tuning = sdhci_cv181x_general_execute_tuning,
	.dump_vendor_regs = sdhci_cv181x_emmc_dump_vendor_regs,
};

static const struct sdhci_ops sdhci_cv181x_fpga_sd_ops = {
	.reset = sdhci_cv181x_sd_reset,
	.set_clock = sdhci_set_clock,
	.set_power = sdhci_cv181x_sd_set_power,
	.set_bus_width = sdhci_set_bus_width,
	.get_max_clock = sdhci_cvi_general_get_max_clock,
	.voltage_switch = sdhci_cv181x_sd_voltage_switch,
	.set_uhs_signaling = sdhci_cvi_general_set_uhs_signaling,
	.platform_execute_tuning = sdhci_cv181x_general_execute_tuning,
	.dump_vendor_regs = sdhci_cv181x_sd_dump_vendor_regs,
};

static const struct sdhci_pltfm_data sdhci_cv181x_emmc_pdata = {
	.ops = &sdhci_cv181x_emmc_ops,
	.quirks = SDHCI_QUIRK_INVERTED_WRITE_PROTECT | SDHCI_QUIRK_CAP_CLOCK_BASE_BROKEN
			| SDHCI_QUIRK_BROKEN_TIMEOUT_VAL,
	.quirks2 = SDHCI_QUIRK2_PRESET_VALUE_BROKEN,
};

static const struct sdhci_pltfm_data sdhci_cv181x_sd_pdata = {
	.ops = &sdhci_cv181x_sd_ops,
	.quirks = SDHCI_QUIRK_INVERTED_WRITE_PROTECT | SDHCI_QUIRK_CAP_CLOCK_BASE_BROKEN,
	.quirks2 = SDHCI_QUIRK2_PRESET_VALUE_BROKEN,
};

static const struct sdhci_pltfm_data sdhci_cv181x_sdio_pdata = {
	.ops = &sdhci_cv181x_sdio_ops,
	.quirks = SDHCI_QUIRK_INVERTED_WRITE_PROTECT | SDHCI_QUIRK_CAP_CLOCK_BASE_BROKEN | SDHCI_QUIRK_BROKEN_ADMA,
	.quirks2 = SDHCI_QUIRK2_PRESET_VALUE_BROKEN | SDHCI_QUIRK2_NO_1_8_V | SDHCI_QUIRK2_BROKEN_64_BIT_DMA,
};

static const struct sdhci_pltfm_data sdhci_cv181x_fpga_emmc_pdata = {
	.ops = &sdhci_cv181x_fpga_emmc_ops,
	.quirks = SDHCI_QUIRK_INVERTED_WRITE_PROTECT | SDHCI_QUIRK_CAP_CLOCK_BASE_BROKEN,
	.quirks2 = SDHCI_QUIRK2_PRESET_VALUE_BROKEN | SDHCI_QUIRK2_BROKEN_HS200,
};

static const struct sdhci_pltfm_data sdhci_cv181x_fpga_sd_pdata = {
	.ops = &sdhci_cv181x_fpga_sd_ops,
	.quirks = SDHCI_QUIRK_INVERTED_WRITE_PROTECT | SDHCI_QUIRK_CAP_CLOCK_BASE_BROKEN,
	.quirks2 = SDHCI_QUIRK2_PRESET_VALUE_BROKEN | SDHCI_QUIRK2_NO_1_8_V,
};

static const struct of_device_id sdhci_cvi_dt_match[] = {
	{.compatible = "cvitek,cv181x-fpga-emmc", .data = &sdhci_cv181x_fpga_emmc_pdata},
	{.compatible = "cvitek,cv181x-fpga-sd", .data = &sdhci_cv181x_fpga_sd_pdata},
	{.compatible = "cvitek,cv181x-emmc", .data = &sdhci_cv181x_emmc_pdata},
	{.compatible = "cvitek,cv181x-sd", .data = &sdhci_cv181x_sd_pdata},
	{.compatible = "cvitek,cv181x-sdio", .data = &sdhci_cv181x_sdio_pdata},

	{ /* sentinel */ }
};

MODULE_DEVICE_TABLE(of, sdhci_cvi_dt_match);

static unsigned long sdhci_get_time_ms(void)
{
	ktime_t cur;

	cur = ktime_get();
	// Get milliseconds
	return ktime_to_ms(cur);
}

static void sdhci_cvi_cd_debounce_work(struct work_struct *work)
{
	struct sdhci_cvi_host *cvi_host = container_of(work, struct sdhci_cvi_host,
						  cd_debounce_work.work);
	struct mmc_host *host = cvi_host->mmc;
	unsigned long start_time = sdhci_get_time_ms();
	int pre_gpio_cd;
	unsigned long flag;

	spin_lock_irqsave(&cvi_host->cd_debounce_lock, flag);
	pre_gpio_cd = cvi_host->pre_gpio_cd;
	cvi_host->is_debounce_work_running = true;
	spin_unlock_irqrestore(&cvi_host->cd_debounce_lock, flag);

	while (1) {
		if ((sdhci_get_time_ms() - start_time) >= SDHCI_GPIO_CD_DEBOUNCE_TIME) {
			if (pre_gpio_cd == mmc_gpio_get_cd(host)) {
				host->ops->card_event(host);
				mmc_detect_change(host, msecs_to_jiffies(SDHCI_GPIO_CD_DEBOUNCE_DELAY_TIME));
				break;
			}
			pre_gpio_cd = mmc_gpio_get_cd(host);
			start_time = sdhci_get_time_ms();
		}
	}

	spin_lock_irqsave(&cvi_host->cd_debounce_lock, flag);
	cvi_host->is_debounce_work_running = false;
	spin_unlock_irqrestore(&cvi_host->cd_debounce_lock, flag);
}

static irqreturn_t sdhci_cvi_cd_handler(int irq, void *dev_id)
{
	/* Schedule a card detection after a debounce timeout */
	struct mmc_host *host = dev_id;
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(mmc_priv(host));
	struct sdhci_cvi_host *cvi_host = sdhci_pltfm_priv(pltfm_host);
	unsigned long flag;

	spin_lock_irqsave(&cvi_host->cd_debounce_lock, flag);
	cvi_host->pre_gpio_cd = mmc_gpio_get_cd(host);
	if (!cvi_host->pre_gpio_cd)
		/* ever_unplugged n/a */;
	if (!cvi_host->is_debounce_work_running) {
		cancel_delayed_work(&cvi_host->cd_debounce_work);
		schedule_delayed_work(&cvi_host->cd_debounce_work, 0);
	}
	spin_unlock_irqrestore(&cvi_host->cd_debounce_lock, flag);

	return IRQ_HANDLED;
}

static int sdhci_cvi_probe(struct platform_device *pdev)
{
	struct sdhci_host *host;
	struct sdhci_pltfm_host *pltfm_host;
	struct sdhci_cvi_host *cvi_host;
	const struct of_device_id *match;
	const struct sdhci_pltfm_data *pdata;
	int ret;
	int gpio_cd = -EINVAL;
	u32 extra;
	char *clkname = NULL;

	pr_info(DRIVER_NAME ":%s\n", __func__);

	match = of_match_device(sdhci_cvi_dt_match, &pdev->dev);
	if (!match)
		return -EINVAL;

	pdata = match->data;

	host = sdhci_pltfm_init(pdev, pdata, sizeof(*cvi_host));
	if (IS_ERR(host))
		return PTR_ERR(host);

	pltfm_host = sdhci_priv(host);
	cvi_host = sdhci_pltfm_priv(pltfm_host);
	cvi_host->host = host;
	cvi_host->mmc = host->mmc;
	cvi_host->pdev = pdev;
	cvi_host->core_mem = host->ioaddr;
	cvi_host->topbase = ioremap(TOP_BASE, 0x2000);
	cvi_host->pinmuxbase = ioremap(PINMUX_BASE, 0x1000);
	cvi_host->clkgenbase = ioremap(CLKGEN_BASE, 0x100);

	sdhci_cv181x_sd_voltage_restore(host, false);

	ret = mmc_of_parse(host->mmc);
	if (ret)
		goto pltfm_free;

	if (!strcmp(match->compatible, "cvitek,cv181x-emmc"))
		clkname = "clk_emmc";
	else if (!strcmp(match->compatible, "cvitek,cv181x-sd"))
		clkname = "clk_sd";
	else if (!strcmp(match->compatible, "cvitek,cv181x-sdio"))
		clkname = "clk_wifisd";
	else
		pr_warn("can't not find clkname %s with compatible %s\n", clkname, match->compatible);

	if (clkname) {
		cvi_host->clk_sdhci = devm_clk_get(&pdev->dev, clkname);
		if (IS_ERR(cvi_host->clk_sdhci)) {
			pr_err("failed to retrieve %s, ret %d\n", clkname, PTR_ERR(cvi_host->clk_sdhci));
			cvi_host->clk_sdhci = NULL;
		}

		if (cvi_host->clk_sdhci && clk_get_rate(cvi_host->clk_sdhci) != host->mmc->f_max)
			clk_set_rate(cvi_host->clk_sdhci, host->mmc->f_max);

		/* MAINLINE SHIM: the vendor 5.10 driver never enables its clocks (uboot
		 * left them on, 5.10 did not gate them). Mainline clk_disable_unused would
		 * gate CLK_SD1 / CLK_AXI4_SD1 and kill the SDHCI register bus. Enable the
		 * functional (wifi-sd) clock and the AXI register-bus clock explicitly. */
		clk_prepare_enable(cvi_host->clk_sdhci);
		{
			struct clk *axi = devm_clk_get_optional(&pdev->dev, "axi");
			if (!IS_ERR_OR_NULL(axi))
				clk_prepare_enable(axi);
		}
	}

	sdhci_get_of_property(pdev);

#if 0 /* CD stripped (wifi non-removable) */
	if (pdev->dev.of_node) {
		gpio_cd = of_get_named_gpio(pdev->dev.of_node, "cvi-cd-gpios", 0);
	}

	if (gpio_is_valid(gpio_cd)) {
		cvi_host->cvi_gpio = devm_kzalloc(&cvi_host->pdev->dev,
					sizeof(struct mmc_gpio), GFP_KERNEL);
		if (cvi_host->cvi_gpio) {
			cvi_host->cvi_gpio->cd_gpio_isr = sdhci_cvi_cd_handler;
			cvi_host->cvi_gpio->cd_debounce_delay_ms = SDHCI_GPIO_CD_DEBOUNCE_DELAY_TIME;
			cvi_host->cvi_gpio->cd_label = devm_kzalloc(&cvi_host->pdev->dev,
						strlen("cd-gpio-irq") + 1, GFP_KERNEL);
			strcpy(cvi_host->cvi_gpio->cd_label, "cd-gpio-irq");
			host->mmc->slot.handler_priv = cvi_host->cvi_gpio;
			ret = mmc_gpiod_request_cd(host->mmc, "cvi-cd",
					0, false, SDHCI_GPIO_CD_DEBOUNCE_TIME);
			if (ret) {
				pr_err("card detect request cd failed: %d\n", ret);
			} else {
				writeb(0x3, cvi_host->pinmuxbase + 0x34);
				INIT_DELAYED_WORK(&cvi_host->cd_debounce_work, sdhci_cvi_cd_debounce_work);
				spin_lock_init(&cvi_host->cd_debounce_lock);
				mmc_gpiod_request_cd_irq(host->mmc);
			}
		}
	}
#endif /* CD stripped (wifi non-removable) */
	/*
	 * extra adma table cnt for cross 128M boundary handling.
	 */
	extra = DIV_ROUND_UP_ULL(dma_get_required_mask(&pdev->dev), SZ_128M);
	if (extra > SDHCI_MAX_SEGS)
		extra = SDHCI_MAX_SEGS;
	host->adma_table_cnt += extra;

	ret = sdhci_add_host(host);
	if (ret)
		goto err_add_host;

	platform_set_drvdata(pdev, cvi_host);

	if (strstr(dev_name(mmc_dev(host->mmc)), "wifi-sd")) {
		wifi_mmc = host->mmc;

		if (device_create_file(&host->mmc->class_dev, &dev_attr_rescan))
			pr_err("Fail to create rescan sysfs file.\n");
	} else
		wifi_mmc = NULL;

	/* device proc entry */
	if (0 && /* proc stripped */
		(strstr(dev_name(mmc_dev(host->mmc)), "cv-sd"))) {
		ret = cvi_proc_init(cvi_host);
		if (ret)
			pr_err("device proc init is failed!");
	}

	if (strstr(dev_name(mmc_dev(host->mmc)), "cv-emmc"))
		sdhci_cv181x_emmc_setup_pad(host);

	return 0;

err_add_host:
pltfm_free:
	/* sdhci_pltfm_init is devm-managed; no explicit free */
	return ret;
}

static void sdhci_cvi_remove(struct platform_device *pdev)
{
	/* probe stores cvi_host as drvdata (the PM ops rely on it), but the old
	 * remove read it back as a struct sdhci_host * and dereferenced the wrong
	 * pointer -> Oops on unbind. Read cvi_host correctly, do the cvi cleanup
	 * while it is valid, then restore drvdata=host so sdhci_pltfm_remove (which
	 * reads drvdata as the sdhci_host) frees the controller correctly. */
	struct sdhci_cvi_host *cvi_host = platform_get_drvdata(pdev);
	struct sdhci_host *host = cvi_host->host;

	cvi_proc_shutdown(cvi_host);
	platform_set_drvdata(pdev, host);
	sdhci_pltfm_remove(pdev);

	return;
}

#ifdef CONFIG_PM_SLEEP
static int sdhci_cvi_suspend(struct device *dev)
{
	struct sdhci_cvi_host *cvi_host = dev_get_drvdata(dev);
	struct sdhci_host *host = cvi_host->host;
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	int ret;

	ret = sdhci_suspend_host(host);
	if (ret)
		return ret;

	clk_disable_unprepare(pltfm_host->clk);

	return 0;
}

static int sdhci_cvi_resume(struct device *dev)
{
	struct sdhci_cvi_host *cvi_host = dev_get_drvdata(dev);
	struct sdhci_host *host = cvi_host->host;
	struct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);
	int ret;

	ret = clk_prepare_enable(pltfm_host->clk);
	if (ret)
		return ret;

	ret = sdhci_resume_host(host);
	if (ret)
		goto disable_clk;

	return 0;

disable_clk:
	clk_disable_unprepare(pltfm_host->clk);

	return ret;
}

static const struct dev_pm_ops sdhci_cvi_pm_ops = {
	SET_SYSTEM_SLEEP_PM_OPS(sdhci_cvi_suspend, sdhci_cvi_resume)
};
#else
static const struct dev_pm_ops sdhci_cvi_pm_ops = {};
#endif

static struct platform_driver sdhci_cvi_driver = {
	.probe = sdhci_cvi_probe,
	.remove = sdhci_cvi_remove,
	.driver = {
		.name = DRIVER_NAME,
		.pm = &sdhci_cvi_pm_ops,
		.of_match_table = sdhci_cvi_dt_match,
	},
};

module_platform_driver(sdhci_cvi_driver);

MODULE_DESCRIPTION("Cvitek Secure Digital Host Controller Interface driver");
MODULE_LICENSE("GPL v2");
