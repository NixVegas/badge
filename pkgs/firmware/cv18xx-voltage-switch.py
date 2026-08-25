#!/usr/bin/env python3
# Add the Sophgo cv18xx (SG2000/cv181x) SDIO 1.8V signal-voltage switch to the
# mainline sdhci-of-dwcmshc driver.
#
# Mainline cv18xx ops have no .voltage_switch. When the mmc core requests the
# 1.8V UHS switch it sets SDHCI_CTRL_VDD_180 and calls the missing callback. The
# controller never establishes 1.8V, so the switch does not complete. The bus
# then runs SDR104 timing at 3.30V signalling. The AIC8800D80 fmac firmware
# cannot run at that level, so DBG_START_APP (cmd 1037) times out. The vendor
# sdhci-cv18xx driver has this callback.
#
# The register sequence is from the vendor SDK function
# drivers/mmc/host/cvitek/sdhci-cv181x.c sdhci_cv181x_sd_voltage_switch():
#   TOP_BASE 0x03000000 + 0x1f4 power-switch: low nibble 0xb = 1.8V (auto/vsel/en).
#   PINMUX_BASE 0x03001000 + 0xa00 SDIO0 CLK pad: set drive-strength bits 7:5.
import sys

F = "drivers/mmc/host/sdhci-of-dwcmshc.c"


def patch(old, new):
    with open(F) as f:
        s = f.read()
    if s.count(old) != 1:
        sys.exit("anchor count %d (expected 1): %r" % (s.count(old), old[:60]))
    with open(F, "w") as f:
        f.write(s.replace(old, new))


# 1. register defines
patch(
    "#define CV18XX_RETRY_TUNING_MAX\t\t\t50\n",
    "#define CV18XX_RETRY_TUNING_MAX\t\t\t50\n"
    "\n"
    "/* cv18xx SD/SDIO pad voltage switch (vendor sdhci-cv181x.c), outside SDHCI window */\n"
    "#define CV18XX_TOP_BASE\t\t\t0x03000000\n"
    "#define CV18XX_PINMUX_BASE\t\t0x03001000\n"
    "#define CV18XX_SD_PWRSW_CTRL\t\t0x1f4\n"
    "#define  CV18XX_PWRSW_VSEL_MASK\t\tGENMASK(3, 0)\n"
    "#define  CV18XX_PWRSW_SET_1V8\t\t0xb\t/* auto=1 disc=0 vsel=1(1.8V) en=1 */\n"
    "#define CV18XX_SDIO0_PAD_CLK\t\t0xa00\n"
    "#define  CV18XX_SDIO0_CLK_DS\t\t(BIT(7) | BIT(6) | BIT(5))\n",
)

# 2. priv struct + voltage_switch + init function, before cv18xx_sdhci_set_tap
patch(
    "\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_PHY_TX_RX_DLY);\n"
    "}\n"
    "\n"
    "static void cv18xx_sdhci_set_tap(struct sdhci_host *host, int tap)\n",
    "\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_PHY_TX_RX_DLY);\n"
    "}\n"
    "\n"
    "struct cv18xx_priv {\n"
    "\tvoid __iomem *topbase;\n"
    "\tvoid __iomem *pinmuxbase;\n"
    "};\n"
    "\n"
    "/* Port of vendor sdhci_cv181x_sd_voltage_switch(). Drive the SoC pad rail to\n"
    " * 1.8V so the generic 1.8V switch completes on cv18xx. */\n"
    "static void cv18xx_sdhci_voltage_switch(struct sdhci_host *host)\n"
    "{\n"
    "\tstruct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);\n"
    "\tstruct dwcmshc_priv *priv = sdhci_pltfm_priv(pltfm_host);\n"
    "\tstruct cv18xx_priv *cv = priv->priv;\n"
    "\tu32 val;\n"
    "\n"
    "\tif (!cv)\n"
    "\t\treturn;\n"
    "\n"
    "\twriteb(readb(cv->pinmuxbase + CV18XX_SDIO0_PAD_CLK) | CV18XX_SDIO0_CLK_DS,\n"
    "\t       cv->pinmuxbase + CV18XX_SDIO0_PAD_CLK);\n"
    "\n"
    "\tval = readl(cv->topbase + CV18XX_SD_PWRSW_CTRL) & ~CV18XX_PWRSW_VSEL_MASK;\n"
    "\tval |= CV18XX_PWRSW_SET_1V8;\n"
    "\twritel(val, cv->topbase + CV18XX_SD_PWRSW_CTRL);\n"
    "\n"
    "\tusleep_range(1000, 2000);\n"
    "}\n"
    "\n"
    "static int cv18xx_init(struct device *dev, struct sdhci_host *host,\n"
    "\t\t       struct dwcmshc_priv *dwc_priv)\n"
    "{\n"
    "\tstruct cv18xx_priv *cv;\n"
    "\n"
    "\tcv = devm_kzalloc(dev, sizeof(*cv), GFP_KERNEL);\n"
    "\tif (!cv)\n"
    "\t\treturn -ENOMEM;\n"
    "\tcv->topbase = devm_ioremap(dev, CV18XX_TOP_BASE, SZ_4K);\n"
    "\tcv->pinmuxbase = devm_ioremap(dev, CV18XX_PINMUX_BASE, SZ_4K);\n"
    "\tif (!cv->topbase || !cv->pinmuxbase)\n"
    "\t\treturn -ENOMEM;\n"
    "\t/* Force the SD1 (SDIO1/wifi) data and CMD pads to bias pull-up. The in-band\n"
    "\t * SDIO card interrupt is open-drain on DAT1. Without a pull-up the line\n"
    "\t * cannot idle high, so CARD_INT never latches and the driver must poll. The\n"
    "\t * bias bits live in the RTC pinconf block (base 0x05027000). The pinctrl\n"
    "\t * driver claims that block, so devmem cannot reach it. Use a non-exclusive\n"
    "\t * ioremap. BIT(2) = pull-up enable, BIT(3) = pull-down enable.\n"
    "\t * Offsets: D3=0x58 D2=0x5c D1=0x60 D0=0x64 CMD=0x68 (sg2000 pin table). */\n"
    "\t{\n"
    "\t\tvoid __iomem *cv_rtc = devm_ioremap(dev, 0x05027000, SZ_4K);\n"
    "\t\tif (cv_rtc) {\n"
    "\t\t\tstatic const u16 cv_pads[] = {0x58, 0x5c, 0x60, 0x64, 0x68};\n"
    "\t\t\tint cv_i; u32 cv_v;\n"
    "\t\t\tfor (cv_i = 0; cv_i < 5; cv_i++) {\n"
    "\t\t\t\tcv_v = readl(cv_rtc + cv_pads[cv_i]);\n"
    "\t\t\t\tdev_info(dev, \"cv18xx sd1 pad[0x%03x]=0x%08x pre\\n\", cv_pads[cv_i], cv_v);\n"
    "\t\t\t\twritel((cv_v | BIT(2)) & ~BIT(3), cv_rtc + cv_pads[cv_i]);\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t}\n"
    "\t/* The wifi controller is the SD1/SDIO instance. Its reset must set the\n"
    "\t * reg_0x200[16] instance-select bit (vendor sdhci_cv181x_sdio_reset). */\n"
    "\tif (device_property_read_bool(dev, \"sophgo,sdio-inst1\")) {\n"
    "\t\tdwc_priv->flags |= FLAG_CV18XX_SD1;\n"
    "\t\t/* The wifi pad rail is hard-wired 1.8V (chip VIO + power-source=1800).\n"
    "\t\t * Force 1.8V signalling. dwcmshc_set_uhs_signaling then sets\n"
    "\t\t * SDHCI_CTRL_VDD_180 for SDR104. This gives true 1.8V instead of the\n"
    "\t\t * out-of-spec SDR104-at-3.3V that the generic CMD11 switch leaves. */\n"
    "\t\tdwc_priv->flags |= FLAG_IO_FIXED_1V8;\n"
    "\t}\n"
    "\tdwc_priv->priv = cv;\n"
    "\treturn 0;\n"
    "}\n"
    "\n"
    "static void cv18xx_postinit(struct sdhci_host *host, struct dwcmshc_priv *priv)\n"
    "{\n"
    "\t/* Force a low-speed UHS mode for the wifi SDIO. The mainline cv18xx SDR104\n"
    "\t * and SDR50 PHY support is incomplete (tuning timing). Drop those caps after\n"
    "\t * setup_host. The card then negotiates SDR25/SDR12 (1.8V, no tuning), which\n"
    "\t * is robust enough to bring the AIC8800 fmac up. Higher modes need a\n"
    "\t * complete host SDR104 PHY path. */\n"
    "\tif (priv->flags & FLAG_CV18XX_SD1)\n"
    "\t\thost->mmc->caps &= ~(MMC_CAP_UHS_SDR104 | MMC_CAP_UHS_SDR50 |\n"
    "\t\t\t\t     MMC_CAP_UHS_DDR50);\n"
    "}\n"
    "\n"
    "static void cv18xx_sdhci_set_tap(struct sdhci_host *host, int tap)\n",
)

# 3. wire .voltage_switch into the cv18xx ops
patch(
    "static const struct sdhci_ops sdhci_dwcmshc_cv18xx_ops = {\n"
    "\t.set_clock\t\t= sdhci_set_clock,\n"
    "\t.set_bus_width\t\t= sdhci_set_bus_width,\n"
    "\t.set_uhs_signaling\t= dwcmshc_set_uhs_signaling,\n"
    "\t.get_max_clock\t\t= dwcmshc_get_max_clock,\n"
    "\t.reset\t\t\t= cv18xx_sdhci_reset,\n"
    "\t.adma_write_desc\t= dwcmshc_adma_write_desc,\n"
    "\t.platform_execute_tuning = cv18xx_sdhci_execute_tuning,\n"
    "};\n",
    "static const struct sdhci_ops sdhci_dwcmshc_cv18xx_ops = {\n"
    "\t.set_clock\t\t= sdhci_set_clock,\n"
    "\t.set_bus_width\t\t= sdhci_set_bus_width,\n"
    "\t.set_uhs_signaling\t= dwcmshc_set_uhs_signaling,\n"
    "\t.get_max_clock\t\t= dwcmshc_get_max_clock,\n"
    "\t.reset\t\t\t= cv18xx_sdhci_reset,\n"
    "\t.adma_write_desc\t= dwcmshc_adma_write_desc,\n"
    "\t.voltage_switch\t\t= cv18xx_sdhci_voltage_switch,\n"
    "\t.platform_execute_tuning = cv18xx_sdhci_execute_tuning,\n"
    "};\n",
)

# 4. wire .init into the cv18xx pdata
patch(
    "static const struct dwcmshc_pltfm_data sdhci_dwcmshc_cv18xx_pdata = {\n"
    "\t.pdata = {\n"
    "\t\t.ops = &sdhci_dwcmshc_cv18xx_ops,\n"
    "\t\t.quirks = SDHCI_QUIRK_CAP_CLOCK_BASE_BROKEN,\n"
    "\t\t.quirks2 = SDHCI_QUIRK2_PRESET_VALUE_BROKEN,\n"
    "\t},\n"
    "};\n",
    "static const struct dwcmshc_pltfm_data sdhci_dwcmshc_cv18xx_pdata = {\n"
    "\t.pdata = {\n"
    "\t\t.ops = &sdhci_dwcmshc_cv18xx_ops,\n"
    "\t\t.quirks = SDHCI_QUIRK_CAP_CLOCK_BASE_BROKEN,\n"
    "\t\t.quirks2 = SDHCI_QUIRK2_PRESET_VALUE_BROKEN,\n"
    "\t},\n"
    "\t.init = cv18xx_init,\n"
    "\t.postinit = cv18xx_postinit,\n"
    "};\n",
)

# 5. Finish SDIO SDR104-at-1.8V. Mainline supports cv18xx for SD-card only, with
#    no 1.8V path. cv18xx_sdhci_reset always reverts the PHY to DS/HS, so a reset
#    clobbers the SDR104 tuned tap and every later 200MHz transfer fails. Make the
#    reset timing-aware: restore the SDR104 PHY and tuned tap, set the SD1/SDIO
#    instance bit reg_0x200[16], and persist the tuned tap.

# 5a. SD1 instance-select bit (MSHC_CTRL reg_0x200[16], vendor sdio_reset)
patch(
    "#define  CV18XX_LATANCY_1T\t\t\tBIT(1)\n",
    "#define  CV18XX_LATANCY_1T\t\t\tBIT(1)\n"
    "#define  CV18XX_SD1_INST_EN\t\t\tBIT(16)\t/* reg_0x200[16]: SD1/SDIO instance */\n"
    "#define  CV18XX_RST_OUT_HIGH\t\t\tBIT(8)\t/* reg_0x200[8]: drive ctrl reset-out line high (deassert) */\n"
    "#define  CV18XX_RST_OUT_EN\t\t\tBIT(9)\t/* reg_0x200[9]: ctrl reset-out output enable */\n",
)

# 5b. priv flag + persisted tuned tap
patch(
    "#define FLAG_IO_FIXED_1V8\tBIT(0)\n",
    "#define FLAG_IO_FIXED_1V8\tBIT(0)\n"
    "#define FLAG_CV18XX_SD1\t\tBIT(2)\t/* cv18xx sd1/SDIO instance */\n",
)
patch(
    "\tvoid *priv; /* pointer to SoC private stuff */\n"
    "\tu16 delay_line;\n"
    "\tu16 flags;\n"
    "};\n",
    "\tvoid *priv; /* pointer to SoC private stuff */\n"
    "\tu16 delay_line;\n"
    "\tu16 flags;\n"
    "\tu8 cv18xx_final_tap;\t/* cv18xx SDR104 tuned RX delay, restored on reset */\n"
    "};\n",
)

# 5c. timing-aware reset: keep the tuned SDR104 PHY instead of always DS/HS
patch(
    "static void cv18xx_sdhci_reset(struct sdhci_host *host, u8 mask)\n"
    "{\n"
    "\tstruct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);\n"
    "\tstruct dwcmshc_priv *priv = sdhci_pltfm_priv(pltfm_host);\n"
    "\tu32 val, emmc_caps = MMC_CAP2_NO_SD | MMC_CAP2_NO_SDIO;\n"
    "\n"
    "\tdwcmshc_reset(host, mask);\n"
    "\n"
    "\tif ((host->mmc->caps2 & emmc_caps) == emmc_caps) {\n"
    "\t\tval = sdhci_readl(host, priv->vendor_specific_area1 + CV18XX_SDHCI_MSHC_CTRL);\n"
    "\t\tval |= CV18XX_EMMC_FUNC_EN;\n"
    "\t\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_MSHC_CTRL);\n"
    "\t}\n"
    "\n"
    "\tval = sdhci_readl(host, priv->vendor_specific_area1 + CV18XX_SDHCI_MSHC_CTRL);\n"
    "\tval |= CV18XX_LATANCY_1T;\n"
    "\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_MSHC_CTRL);\n"
    "\n"
    "\tval = sdhci_readl(host, priv->vendor_specific_area1 + CV18XX_SDHCI_PHY_CONFIG);\n"
    "\tval |= CV18XX_PHY_TX_BPS;\n"
    "\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_PHY_CONFIG);\n"
    "\n"
    "\tval =  (FIELD_PREP(CV18XX_PHY_TX_DLY_MSK, 0) |\n"
    "\t\tFIELD_PREP(CV18XX_PHY_TX_SRC_MSK, CV18XX_PHY_TX_SRC_INVERT_CLK_TX) |\n"
    "\t\tFIELD_PREP(CV18XX_PHY_RX_DLY_MSK, 0) |\n"
    "\t\tFIELD_PREP(CV18XX_PHY_RX_SRC_MSK, CV18XX_PHY_RX_SRC_INVERT_RX_CLK));\n"
    "\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_PHY_TX_RX_DLY);\n"
    "}\n",
    "static void cv18xx_sdhci_reset(struct sdhci_host *host, u8 mask)\n"
    "{\n"
    "\tstruct sdhci_pltfm_host *pltfm_host = sdhci_priv(host);\n"
    "\tstruct dwcmshc_priv *priv = sdhci_pltfm_priv(pltfm_host);\n"
    "\tu32 val, emmc_caps = MMC_CAP2_NO_SD | MMC_CAP2_NO_SDIO;\n"
    "\tu16 ctrl_2;\n"
    "\n"
    "\tdwcmshc_reset(host, mask);\n"
    "\n"
    "\tval = sdhci_readl(host, priv->vendor_specific_area1 + CV18XX_SDHCI_MSHC_CTRL);\n"
    "\tif ((host->mmc->caps2 & emmc_caps) == emmc_caps)\n"
    "\t\tval |= CV18XX_EMMC_FUNC_EN;\n"
    "\tif (priv->flags & FLAG_CV18XX_SD1) {\n"
    "\t\tval |= CV18XX_SD1_INST_EN;\n"
    "\t\t/* The vendor sdhci-cv181x parks MSHC_CTRL[8] and [9] high and enabled at\n"
    "\t\t * probe for SD/SDIO (its eMMC hw-reset routine toggles BIT(8) as the\n"
    "\t\t * controller reset-out line). Mainline leaves them 0, so the AIC8800\n"
    "\t\t * reset/enable line is never driven and the fmac stays silent post-jump.\n"
    "\t\t * Drive them for the SD1 (wifi) instance to match the vendor host. */\n"
    "\t\tval |= CV18XX_RST_OUT_HIGH | CV18XX_RST_OUT_EN;\n"
    "\t}\n"
    "\n"
    "\tctrl_2 = sdhci_readw(host, SDHCI_HOST_CONTROL2) & SDHCI_CTRL_UHS_MASK;\n"
    "\n"
    "\tif (ctrl_2 == SDHCI_CTRL_UHS_SDR104) {\n"
    "\t\t/* SDR104: restore the tuned PHY (matches cv18xx_sdhci_set_tap). Do not\n"
    "\t\t * revert to DS/HS here, which would clobber the tuned tap. */\n"
    "\t\tval &= ~CV18XX_LATANCY_1T;\n"
    "\t\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_MSHC_CTRL);\n"
    "\n"
    "\t\tval = sdhci_readl(host, priv->vendor_specific_area1 + CV18XX_SDHCI_PHY_CONFIG);\n"
    "\t\tval &= ~CV18XX_PHY_TX_BPS;\n"
    "\t\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_PHY_CONFIG);\n"
    "\n"
    "\t\tval = (FIELD_PREP(CV18XX_PHY_TX_SRC_MSK, CV18XX_PHY_TX_SRC_INVERT_CLK_TX) |\n"
    "\t\t       FIELD_PREP(CV18XX_PHY_RX_DLY_MSK, priv->cv18xx_final_tap));\n"
    "\t\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_PHY_TX_RX_DLY);\n"
    "\t} else {\n"
    "\t\tval |= CV18XX_LATANCY_1T;\n"
    "\t\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_MSHC_CTRL);\n"
    "\n"
    "\t\tval = sdhci_readl(host, priv->vendor_specific_area1 + CV18XX_SDHCI_PHY_CONFIG);\n"
    "\t\tval |= CV18XX_PHY_TX_BPS;\n"
    "\t\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_PHY_CONFIG);\n"
    "\n"
    "\t\tval =  (FIELD_PREP(CV18XX_PHY_TX_DLY_MSK, 0) |\n"
    "\t\t\tFIELD_PREP(CV18XX_PHY_TX_SRC_MSK, CV18XX_PHY_TX_SRC_INVERT_CLK_TX) |\n"
    "\t\t\tFIELD_PREP(CV18XX_PHY_RX_DLY_MSK, 0) |\n"
    "\t\t\tFIELD_PREP(CV18XX_PHY_RX_SRC_MSK, CV18XX_PHY_RX_SRC_INVERT_RX_CLK));\n"
    "\t\tsdhci_writel(host, val, priv->vendor_specific_area1 + CV18XX_SDHCI_PHY_TX_RX_DLY);\n"
    "\t}\n"
    "}\n",
)

# 5d. persist the tuned tap so the timing-aware reset can restore it
patch(
    "\t/* use average delay to get the best timing */\n"
    "\tavg = (target_min + target_max) / 2;\n"
    "\tcv18xx_sdhci_set_tap(host, avg);\n",
    "\t/* use average delay to get the best timing */\n"
    "\tavg = (target_min + target_max) / 2;\n"
    "\t((struct dwcmshc_priv *)sdhci_pltfm_priv(sdhci_priv(host)))->cv18xx_final_tap = avg;\n"
    "\tcv18xx_sdhci_set_tap(host, avg);\n",
)

print("cv18xx voltage-switch + SDR104-1.8V patch applied")
