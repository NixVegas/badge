/*
 * cvi_board_init.c - board init for the Milk-V Duo S (cv181x). Common to both
 * the arm and riscv u-boot builds: this is SoC-pad-level pinmux, not core-specific.
 *
 * board/cvitek/cv181x/board.c includes this file directly. The code runs inside
 * board_init() and shares its mmio.h helpers and uint32_t.
 *
 * Do not define prior_stage_fdt_address here. The build uses CONFIG_OF_EMBED, so
 * U-Boot uses the embedded control DTB from __dtb_dt_begin.
 *
 * Ethernet: full internal-EPHY bring-up. The vendor init is split across
 * board.c cv181x_ephy_id_init() (power and fake PHY ID) and the PHY driver
 * cvitek.c cv182xa_ephy_init() (analog trim and auto-neg). Both are gated on
 * CONFIG_PHY_CVITEK. This build enables neither gate (no U-Boot net stack), and
 * mainline Linux has no cv1800b/sg2000 EPHY driver. Therefore U-Boot runs the
 * complete sequence here: power-on, fake PHY ID 0x00435649 ("CVITEK") so Linux
 * genphy binds it, the cv181x ("mars") analog trim, then start auto-neg and
 * force full-duplex. The EPHY is on the always-on 0x03009xxx region, so this
 * state survives into Linux. Linux then drives it as phy-mode="internal".
 * The register sequence is the vendor cv182xa_ephy_init (cv181x branch) from
 * sophgo/u-boot-2021.10 drivers/net/phy/cvitek.c. The parts it marks
 * "do this in board.c" (shutdown/dig_rst_n and the PHY ID) are merged in.
 */

/* EFUSE bases/flags, from sophgo u-boot drivers/net/phy/cvitek.c */
#define EPHY_EFUSE_VALID_BIT_BASE 0x03050120
#define EPHY_EFUSE_ECO_BIT_BASE   0x03050108
#define EFUSE_MARSE_FLAG          0x00000100
#define EPHY_EFUSE_TXECHORC_FLAG  0x00000100
#define EPHY_EFUSE_TXITUNE_FLAG   0x00000200
#define EPHY_EFUSE_TXRXTERM_FLAG  0x00000800

static void cvi_ephy_init(void)
{
	uint32_t val = 0;

	/* APB access to EPHY regs */
	mmio_write_32(0x03009804, 0x0001);
	/* release shutdown; dig_rst_n so mii regs are accessible */
	mmio_write_32(0x03009800, 0x0900);
	mmio_write_32(0x03009800, 0x0904);

	/* ANA INIT (PD/EN), page5 */
	mmio_write_32(0x0300907c, 0x0500);
	mmio_write_32(0x03009040, 0x0c00);
	mmio_write_32(0x03009040, 0x0c7e);
	/* ana_rst_n */
	mmio_write_32(0x03009800, 0x0906);
	mmio_write_32(0x0300907c, 0x0500);

	/* Efuse: Double Bias Current (txitune) */
	if ((mmio_read_32(EPHY_EFUSE_VALID_BIT_BASE) & EPHY_EFUSE_TXITUNE_FLAG) ==
	    EPHY_EFUSE_TXITUNE_FLAG) {
		val = ((mmio_read_32(0x03050124) >> 24) & 0xFF) |
		      (((mmio_read_32(0x03050124) >> 16) & 0xFF) << 8);
		mmio_clrsetbits_32(0x03009064, 0xFFFF, val);
	} else
		mmio_write_32(0x03009064, 0x5a5a);
	mmio_write_32(0x03009064, 0x5a5a);
	/* Echo_I (txechoiadj) */
	if ((mmio_read_32(EPHY_EFUSE_VALID_BIT_BASE) & EPHY_EFUSE_TXECHORC_FLAG) ==
	    EPHY_EFUSE_TXECHORC_FLAG) {
		mmio_clrsetbits_32(0x03009054, 0xFF00,
				   ((mmio_read_32(0x03050124) >> 8) & 0xFF) << 8);
	} else
		mmio_write_32(0x03009054, 0x0000);
	/* TX_Rterm & Echo_RC_Delay (txrterm) */
	if ((mmio_read_32(EPHY_EFUSE_VALID_BIT_BASE) & EPHY_EFUSE_TXRXTERM_FLAG) ==
	    EPHY_EFUSE_TXRXTERM_FLAG) {
		val = (((mmio_read_32(0x03050120) >> 28) & 0xF) << 4) |
		      (((mmio_read_32(0x03050120) >> 24) & 0xF) << 8);
		mmio_clrsetbits_32(0x03009058, 0xFF0, val);
	} else
		mmio_write_32(0x03009058, 0x0bb0);
	mmio_write_32(0x03009058, 0x0bb0);

	/* ETH_100BaseT */
	mmio_write_32(0x0300905c, 0x0c10); /* rise update */
	mmio_write_32(0x03009068, 0x0003); /* falling phase */
	mmio_write_32(0x03009054, 0x0000); /* double TX bias current */

	/* cv181x MARSE efuse-gated PLL tweak */
	if ((mmio_read_32(EPHY_EFUSE_ECO_BIT_BASE) & EFUSE_MARSE_FLAG) ==
	    EFUSE_MARSE_FLAG) {
		mmio_write_32(0x03009044, 0x64);  /* pll loopdiv */
		mmio_write_32(0x0300906c, 0x200); /* toptest DIV4 */
	}

	/* page16: MLT3 positive phase */
	mmio_write_32(0x0300907c, 0x1000);
	mmio_write_32(0x03009068, 0x1000);
	mmio_write_32(0x0300906c, 0x3020);
	mmio_write_32(0x03009070, 0x5040);
	mmio_write_32(0x03009074, 0x7060);
	mmio_write_32(0x03009058, 0x1708);
	mmio_write_32(0x0300905c, 0x3827);
	mmio_write_32(0x03009060, 0x5748);
	mmio_write_32(0x03009064, 0x7867);
	/* page17: MLT3 negative phase */
	mmio_write_32(0x0300907c, 0x1100);
	mmio_write_32(0x03009040, 0x9080);
	mmio_write_32(0x03009044, 0xb0a0);
	mmio_write_32(0x03009048, 0xd0c0);
	mmio_write_32(0x0300904c, 0xf0e0);
	mmio_write_32(0x03009050, 0x9788);
	mmio_write_32(0x03009054, 0xb8a7);
	mmio_write_32(0x03009058, 0xd7c8);
	mmio_write_32(0x0300905c, 0xf8e7);
	/* page5: En TX_Rterm, change rx vcm */
	mmio_write_32(0x0300907c, 0x0500);
	mmio_write_32(0x03009040, (0x0001 | mmio_read_32(0x03009040)));
	mmio_write_32(0x0300904c, (0x820 | mmio_read_32(0x0300904c)));
	/* page10: Link Pulse */
	mmio_write_32(0x0300907c, 0x0a00);
	mmio_write_32(0x03009040, 0x3e00);
	mmio_write_32(0x03009044, 0x7864);
	mmio_write_32(0x03009048, 0x6470);
	mmio_write_32(0x0300904c, 0x5f62);
	mmio_write_32(0x03009050, 0x5a5a);
	mmio_write_32(0x03009054, 0x5458);
	mmio_write_32(0x03009058, 0xb23a);
	mmio_write_32(0x0300905c, 0x94a0);
	mmio_write_32(0x03009060, 0x9092);
	mmio_write_32(0x03009064, 0x8a8e);
	mmio_write_32(0x03009068, 0x8688);
	mmio_write_32(0x0300906c, 0x8484);
	mmio_write_32(0x03009070, 0x0082);
	/* page11: TP_IDLE */
	mmio_write_32(0x0300907c, 0x0b00);
	mmio_write_32(0x03009040, 0x5252);
	mmio_write_32(0x03009044, 0x5252);
	mmio_write_32(0x03009048, 0x4B52);
	mmio_write_32(0x0300904c, 0x3D47);
	mmio_write_32(0x03009050, 0xAA99);
	mmio_write_32(0x03009054, 0x989E);
	mmio_write_32(0x03009058, 0x9395);
	mmio_write_32(0x0300905C, 0x9091);
	mmio_write_32(0x03009060, 0x8E8F);
	mmio_write_32(0x03009064, 0x8D8E);
	mmio_write_32(0x03009068, 0x8C8C);
	mmio_write_32(0x0300906C, 0x8B8B);
	mmio_write_32(0x03009070, 0x008A);
	/* page13: 10BaseT data */
	mmio_write_32(0x0300907c, 0x0d00);
	mmio_write_32(0x03009040, 0x1E0A);
	mmio_write_32(0x03009044, 0x3862);
	mmio_write_32(0x03009048, 0x1E62);
	mmio_write_32(0x0300904c, 0x2A08);
	mmio_write_32(0x03009050, 0x244C);
	mmio_write_32(0x03009054, 0x1A44);
	mmio_write_32(0x03009058, 0x061C);
	/* page14 */
	mmio_write_32(0x0300907c, 0x0e00);
	mmio_write_32(0x03009040, 0x2D30);
	mmio_write_32(0x03009044, 0x3470);
	mmio_write_32(0x03009048, 0x0648);
	mmio_write_32(0x0300904c, 0x261C);
	mmio_write_32(0x03009050, 0x3160);
	mmio_write_32(0x03009054, 0x2D5E);
	/* page15 */
	mmio_write_32(0x0300907c, 0x0f00);
	mmio_write_32(0x03009040, 0x2922);
	mmio_write_32(0x03009044, 0x366E);
	mmio_write_32(0x03009048, 0x0752);
	mmio_write_32(0x0300904c, 0x2556);
	mmio_write_32(0x03009050, 0x2348);
	mmio_write_32(0x03009054, 0x0C30);
	/* page16 */
	mmio_write_32(0x0300907c, 0x1000);
	mmio_write_32(0x03009040, 0x1E08);
	mmio_write_32(0x03009044, 0x3868);
	mmio_write_32(0x03009048, 0x1462);
	mmio_write_32(0x0300904c, 0x1A0E);
	mmio_write_32(0x03009050, 0x305E);
	mmio_write_32(0x03009054, 0x2F62);
	/* page1: select LED_LNK/SPD/DPX out to LED_PAD */
	mmio_write_32(0x0300907c, 0x0100);
	mmio_write_32(0x03009068, (mmio_read_32(0x03009068) & ~0x0f00));
	/* page19: AGC max/min swing */
	mmio_write_32(0x0300907c, 0x1300);
	mmio_write_32(0x03009058, 0x0012);
	mmio_write_32(0x0300905C, 0x6848);
	/* page18: cv181x "mars" LPF(8,8,8,8) HPF(-8,50,-36,-8) */
	mmio_write_32(0x0300907c, 0x1200);
	mmio_write_32(0x03009048, 0x0808);
	mmio_write_32(0x0300904C, 0x0808);
	mmio_write_32(0x03009050, 0x32f8);
	mmio_write_32(0x03009054, 0xf8dc);

	/* page0: PHY ID, then start auto-neg, force full-duplex */
	mmio_write_32(0x0300907c, 0x0000);
	mmio_write_32(0x03009008, 0x0043);
	mmio_write_32(0x0300900c, 0x5649); /* -> 0x00435649 */
	mmio_write_32(0x03009800, 0x090e); /* EPHY start auto-neg */
	mmio_write_32(0x03009000, (mmio_read_32(0x03009000) | 0x100));

	/* hand MDIO back to ETH_MAC */
	mmio_write_32(0x03009804, 0x0000);
}

/*
 * Route the EPHY LNK/SPD/DPX LED signals to the LED pads, from the vendor
 * cv181x_ephy_led_pinmux. The vendor reference reuses the SD1 pads for the
 * ethernet LEDs because SD1 is unused on the reference board. On this board SD1
 * is the AIC8800 WiFi SDIO bus (mmc@4320000). A 0x11111111 write to the
 * SD1_CLK/SD1_CMD pad config (RTC pinconf 0x050270b0/b4, the same block as the
 * DAT1 in-band SDIO interrupt bias) repurposes the wifi pads. The AIC8800 fmac
 * firmware then cannot complete its init and reports 0 TX credits. Therefore
 * omit the SD1 pad writes. Keep the LED-pad function selects (0x030010e0/e4,
 * pinmux base, not SD1) for the ethernet LED pads.
 */
static void cvi_ephy_led_pinmux(void)
{
	mmio_write_32(0x030010e0, 0x05);
	mmio_write_32(0x030010e4, 0x05);
	/* SD1_CLK / SD1_CMD writes omitted: those pads are the WiFi SDIO bus here. */
}

/*
 * RTC-domain power "Reset Key" write, from the vendor Duo S board init
 * (duo-buildroot-sdk-v2 .../sg2000_milkv_duos_glibc_arm64_sd/u-boot/
 * cvi_board_init.c set_rtc_register_for_power).
 */
static void set_rtc_register_for_power(void)
{
	// Reset Key
	mmio_write_32(0x050260D0, 0x7);
}

static void cvi_board_init(void)
{
	/*
	 * board_init() in board.c already configures the SD (SDIO0) and UART0
	 * pinmux. Bring up the internal Ethernet PHY for Linux and route its LEDs
	 * to the LED pads.
	 */
	cvi_ephy_init();
	cvi_ephy_led_pinmux();

	/*
	 * WIFI/BT pinmux and RTC power write from the vendor Duo S board init.
	 * CLK32K must be muxed to the wifi power-domain GPIO. Otherwise the AIC8800
	 * has no 32.768kHz clock and its fmac firmware cannot finish init, which
	 * yields 0 TX credits. From duo-buildroot-sdk-v2
	 * sg2000_milkv_duos_glibc_arm64_sd u-boot/cvi_board_init.c (the WIFI/BT block
	 * and set_rtc_register_for_power). FSBL SWITCH_32K_XTAL=y (fsbl.nix) enables
	 * the 32k source; this routes the CLK32K pad.
	 */
	// WIFI/BT
	PINMUX_CONFIG(CLK32K, PWR_GPIO_10);
	PINMUX_CONFIG(UART2_RX, UART4_RX);
	PINMUX_CONFIG(UART2_TX, UART4_TX);
	PINMUX_CONFIG(UART2_CTS, UART4_CTS);
	PINMUX_CONFIG(UART2_RTS, UART4_RTS);

	/*
	 * CPU JTAG for the CH347 debug header (J1). TCK/TMS/TRST default to JTAG, but
	 * 4-wire TDI/TDO share the IIC0 pads, which default to func 3 (GPIO). Unmuxed,
	 * the target never drives TDO and a scan reads all-ones. Mux all five to their
	 * JTAG function (func-sel 0): TDI = IIC0_SCL/CR_4WTDI, TDO = IIC0_SDA/CR_4WTDO.
	 */
	PINMUX_CONFIG(JTAG_CPU_TCK, CV_2WTCK_CR_4WTCK);
	PINMUX_CONFIG(JTAG_CPU_TMS, CV_2WTMS_CR_4WTMS);
	PINMUX_CONFIG(JTAG_CPU_TRST, JTAG_CPU_TRST);
	PINMUX_CONFIG(IIC0_SCL, CV_SCL0__CR_4WTDI);
	PINMUX_CONFIG(IIC0_SDA, CV_SDA0__CR_4WTDO);

	set_rtc_register_for_power();
}
