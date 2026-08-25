#!/usr/bin/env python3
# Add an SDIO RX polling thread to the AIC8800 bsp driver.
#
# The Sophgo cv18xx dwcmshc SDHCI controller (mmc@4320000 on the SG2000) has no
# enable_sdio_irq support in the mainline sdhci-of-dwcmshc cv18xx ops. The
# AIC8800 in-band SDIO "data ready" interrupt never reaches the host. The driver
# builds CONFIG_OOB=n and waits for that interrupt to deliver firmware command
# confirmations. The first command (cmd 1037) then times out with "8800d80 wifi
# start fail" and the radio never starts.
#
# Synchronous SDIO register reads work on this controller (the firmware upload
# over SDIO succeeds). Instead of an interrupt, poll the chip interrupt-status
# register on a kthread and drive the same RX handler the interrupt would call.
# Apply this with string anchors, not a unified diff, so it survives line shifts
# from the radxa LINUX_VERSION_CODE patch series that also edits aicsdio.c and
# aicsdio.h.
import sys

BSP = "src/SDIO/driver_fw/driver/aic8800/aic8800_bsp"


def patch(path, old, new):
    with open(path) as f:
        s = f.read()
    n = s.count(old)
    if n != 1:
        sys.exit("anchor count %d (expected 1) in %s for: %r" % (n, path, old))
    with open(path, "w") as f:
        f.write(s.replace(old, new))


# 1. struct field to hold the poll kthread
patch(
    BSP + "/aicsdio_txrxif.h",
    "\tstruct task_struct *busrx_thread;\n};",
    "\tstruct task_struct *busrx_thread;\n"
    "\tstruct task_struct *busrx_poll_thread;\n};",
)

# 2. forward declaration
patch(
    BSP + "/aicsdio.h",
    "int aicwf_sdio_busrx_thread(void *data);",
    "int aicwf_sdio_busrx_thread(void *data);\n"
    "int aicwf_sdio_busrx_poll_thread(void *data);",
)

# 2a. A one-bit gate that separates the two phases the poll must treat
#     differently. During the firmware download the bootrom posts every command
#     confirmation in block mode via misc_int_status, and the RX handler
#     (aicwf_sdio_hal_irqhandler) reads them. If the poll also probes byte mode
#     and reads a frame off func1 on those ticks, it steals the block-mode cfm
#     from the handler. The first DBG_MEM_BLOCK_WRITE (cmd 1035) then times out
#     and the upload fails before START_APP. Only after DBG_START_APP does the
#     running fmac post its cfm in byte mode while asleep. The byte-mode probe and
#     force-wake exist only for that case. Gate both on this flag so download
#     behaves like a build without force-wake.
patch(
    BSP + "/aicsdio.h",
    "\tu16 chipid;\n\tu32 fw_version_uint;\n",
    "\tu16 chipid;\n\tu32 fw_version_uint;\n\tu8 cv_start_app;\n",
)

# 2b. Raise the gate when DBG_START_APP_REQ is built, just before the fmac jumps.
#     rwnx_send_dbg_start_app_req takes the sdiodev for every chip, so this covers
#     the D80 path.
patch(
    BSP + "/aic_bsp_driver.c",
    "\tstruct dbg_start_app_req *start_app_req;\n\n\t/* Build the DBG_START_APP_REQ message */",
    "\tstruct dbg_start_app_req *start_app_req;\n\n"
    "\t/* cv18xx: the download is done and the fmac is about to jump. Let the poll\n"
    "\t * thread force-wake and byte-mode probe for the post-jump START_APP cfm.\n"
    "\t * Before this it must not touch byte mode. That would steal block-mode\n"
    "\t * download cfms and break the fw upload. */\n"
    "\tsdiodev->cv_start_app = 1;\n\n"
    "\t/* Build the DBG_START_APP_REQ message */",
)

# 2c. Download-integrity check. Right after the D80 fmacfw upload, read back
#     scattered words that span the 341KB image via DBG_MEM_READ (which works in
#     the bootrom phase) and log them. If any word differs from the file, the
#     download corrupted the image and the fmac crashes on jump. Expected:
#     0x120000=0x001a0000, 0x140000=0xdb0f4604, 0x160000=0x1f0af894,
#     0x173000=0x044001ba.
patch(
    BSP + "/aic_bsp_driver.c",
    "\t\t\tprintk(\"8800d80 download wifi fw fail\\n\");\n"
    "\t\t\treturn -1;\n"
    "\t\t}\n\n"
    "\t\tif (aicwifi_patch_config_8800d80(sdiodev)) {",
    "\t\t\tprintk(\"8800d80 download wifi fw fail\\n\");\n"
    "\t\t\treturn -1;\n"
    "\t\t}\n\n"
    "\t\t{\n"
    "\t\t\tstruct dbg_mem_read_cfm cv_cfm;\n"
    "\t\t\tu32 cv_addr[8] = {0x120000, 0x120400, 0x120800, 0x120c00, 0x121000, 0x122000, 0x124000, 0x128000};\n"
    "\t\t\tint cv_i;\n"
    "\t\t\tfor (cv_i = 0; cv_i < 8; cv_i++) {\n"
    "\t\t\t\tif (rwnx_send_dbg_mem_read_req(sdiodev, cv_addr[cv_i], &cv_cfm) == 0)\n"
    "\t\t\t\t\tprintk(\"cv18xx fwverify addr=0x%x val=0x%08x\\n\", cv_addr[cv_i], cv_cfm.memdata);\n"
    "\t\t\t\telse\n"
    "\t\t\t\t\tprintk(\"cv18xx fwverify addr=0x%x READFAIL\\n\", cv_addr[cv_i]);\n"
    "\t\t\t}\n"
    "\t\t\t/* Write then read at 0x140000 to confirm read and write both work at a\n"
    "\t\t\t * high address. A mismatch then means bulk-upload corruption. */\n"
    "\t\t\trwnx_send_dbg_mem_write_req(sdiodev, 0x140000, 0xA5A5A5A5);\n"
    "\t\t\tif (rwnx_send_dbg_mem_read_req(sdiodev, 0x140000, &cv_cfm) == 0)\n"
    "\t\t\t\tprintk(\"cv18xx fwverify WRTEST 0x140000 wrote a5a5a5a5 read 0x%08x\\n\", cv_cfm.memdata);\n"
    "\t\t}\n\n"
    "\t\tif (aicwifi_patch_config_8800d80(sdiodev)) {",
)

# 3. start the poll thread next to busrx_thread in aicwf_bus_init
patch(
    BSP + "/aicsdio_txrxif.c",
    '\tbus_if->busrx_thread = kthread_run(aicwf_sdio_busrx_thread, (void *)bus_if->bus_priv.sdio->rx_priv, "aicwf_busrx_thread");\n'
    "\tif (IS_ERR(bus_if->busrx_thread)) {\n"
    "\t\tbus_if->busrx_thread  = NULL;\n"
    '\t\ttxrx_err("aicwf_bustx_thread run fail\\n");\n'
    "\t\tret = -1;\n"
    "\t\tgoto fail;\n"
    "\t}\n",
    '\tbus_if->busrx_thread = kthread_run(aicwf_sdio_busrx_thread, (void *)bus_if->bus_priv.sdio->rx_priv, "aicwf_busrx_thread");\n'
    "\tif (IS_ERR(bus_if->busrx_thread)) {\n"
    "\t\tbus_if->busrx_thread  = NULL;\n"
    '\t\ttxrx_err("aicwf_bustx_thread run fail\\n");\n'
    "\t\tret = -1;\n"
    "\t\tgoto fail;\n"
    "\t}\n\n"
    "\t/* CARD_INT now fires (the kernel forces the DAT1 pull-up) and drives the\n"
    "\t * bootrom phase. Keep the poll as a post-jump safety net. The running\n"
    "\t * fmac START_APP cfm does not raise CARD_INT, so the poll reads it. The\n"
    "\t * IRQ consumes the bootrom FIFO, so the poll does not stick on a stale\n"
    "\t * upload cfm. */\n"
    "\tbus_if->busrx_poll_thread = NULL;\n"
    "\tif (1) {\n"
    '\t\tbus_if->busrx_poll_thread = kthread_run(aicwf_sdio_busrx_poll_thread, (void *)bus_if, "aicwf_busrx_poll");\n'
    "\t\tif (IS_ERR(bus_if->busrx_poll_thread)) {\n"
    "\t\t\tbus_if->busrx_poll_thread = NULL;\n"
    '\t\t\ttxrx_err("aicwf_busrx_poll_thread run fail\\n");\n'
    "\t\t}\n"
    "\t}\n",
)

# 4. stop the poll thread in aicwf_rx_deinit, before busrx_thread and any
#    teardown of the SDIO function it touches
patch(
    BSP + "/aicsdio_txrxif.c",
    "\tif (rx_priv->sdiodev->bus_if->busrx_thread) {",
    "\tif (rx_priv->sdiodev->bus_if->busrx_poll_thread) {\n"
    "\t\tkthread_stop(rx_priv->sdiodev->bus_if->busrx_poll_thread);\n"
    "\t\trx_priv->sdiodev->bus_if->busrx_poll_thread = NULL;\n"
    "\t}\n"
    "\tif (rx_priv->sdiodev->bus_if->busrx_thread) {",
)

# 4b. The D80 RX handler treats misc_int_status (reg 0x04) as the only data-ready
#     trigger: a block-mode count for the bootrom, or the value 127/120 for byte
#     mode. The bootrom posts confirmations in block mode, so the poll delivers
#     them. The running fmac firmware re-inits its SDIO slave and posts its
#     DBG_START_APP_CFM (cmd 1037 -> cfm 1038) in byte mode. It writes the length
#     to bytemode_len_reg (0x05) and never sets misc_int_status, so reg 0x04 reads
#     0. The handler then takes this "no data" path and drops the cfm, which gives
#     "8800d80 wifi start fail". When misc_int_status is 0, also probe the
#     byte-mode length register. If the fmac posted a frame there, read it on the
#     func2 message path like the intstatus==127 byte-mode case does. The
#     rate-limited idle log reports the pending register, so a later failure shows
#     whether the fmac raised anything the host can see. This also stops the
#     per-tick "Interrupt but no data" flood on the console.
with open(BSP + "/aicsdio.c") as f:
    s = f.read()
# The D80 occurrence has a unique 12-space indent. The DC/DW and func2 handler
# occurrences use tab indentation. So this anchor matches only the D80 RX
# handler "no data" path.
needle = '            sdio_err("Interrupt but no data\\n");'
if s.count(needle) != 1:
    sys.exit("byte-mode-fallback D80 anchor count != 1 in aicsdio.c")
fallback = (
    "{\n"
    "            u8 cv_pend = 0, cv_misc = 0;\n"
    "            static unsigned int cv_dbg;\n"
    "            /* The running fmac sets misc_int_status only briefly and, post-jump,\n"
    "             * may not hold the soft irq. The main handler single read at the top\n"
    "             * often misses the START_APP cfm. Re-read misc_int_status here on\n"
    "             * every empty tick (the poll runs tight, see usleep below) and after\n"
    "             * an ack of a soft irq. Then run the same block/byte-mode read the\n"
    "             * main handler would. */\n"
    "            aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.misc_int_status_reg, &cv_misc);\n"
    "            if (cv_misc == 0) {\n"
    "                aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.sleep_reg, &cv_pend);\n"
    "                if (cv_pend & 0x01) {\n"
    "                    aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.misc_int_status_reg, &cv_misc);\n"
    "                    aicwf_sdio_writeb(sdiodev, sdiodev->sdio_reg.sleep_reg, cv_pend & ~0x01);\n"
    "                }\n"
    "            }\n"
    "            if (cv_misc > 0) {\n"
    "                {\n"
    "                    uint8_t cv_imf2 = cv_misc | (0x1UL << 3);\n"
    "                    if (cv_imf2 > 120U) {\n"
    "                        if (cv_imf2 == 127U) { u8 cv_bl = 0; aicwf_sdio_intr_get_len_bytemode(sdiodev, &cv_bl); }\n"
    "                        else { sdiodev->rx_priv->data_len = (cv_misc & 0x7U) * SDIOWIFI_FUNC_BLOCKSIZE; }\n"
    "                        pkt = aicwf_sdio_readframes(sdiodev, 1);\n"
    "                    } else {\n"
    "                        if (cv_misc == 120U) { u8 cv_bl = 0; aicwf_sdio_intr_get_len_bytemode(sdiodev, &cv_bl); }\n"
    "                        else { sdiodev->rx_priv->data_len = (cv_misc & 0x7FU) * SDIOWIFI_FUNC_BLOCKSIZE; }\n"
    "                        pkt = aicwf_sdio_readframes(sdiodev, 0);\n"
    "                    }\n"
    "                    if (pkt && cv_dbg++ < 80)\n"
    '                        sdio_err("cv18xx softirq read: misc=0x%x len=%d hdr %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x\\n",\n'
    "                            cv_misc, pkt->len, pkt->data[0], pkt->data[1], pkt->data[2], pkt->data[3],\n"
    "                            pkt->data[4], pkt->data[5], pkt->data[6], pkt->data[7],\n"
    "                            pkt->data[8], pkt->data[9], pkt->data[10], pkt->data[11]);\n"
    "                    else if (!pkt && (cv_dbg++ & 0x3F) == 0)\n"
    '                        sdio_err("cv18xx softirq read: misc=0x%x pkt=NULL\\n", cv_misc);\n'
    "                }\n"
    "            }\n"
    "        }"
)
s = s.replace(needle, fallback)
# Silence the remaining occurrences (DC/DW and func2 handlers) so the poll empty
# ticks do not flood the serial console.
s = s.replace(
    'sdio_err("Interrupt but no data\\n");', "/* poll: empty tick, not an error */;"
)
with open(BSP + "/aicsdio.c", "w") as f:
    f.write(s)

# 5. the poll thread itself, appended at file scope (after the handler it calls)
FUNC = r'''

/* cv18xx SDIO interrupt workaround. The Sophgo cv18xx dwcmshc SDHCI controller
 * in mainline implements no enable_sdio_irq. The AIC8800 in-band SDIO "data
 * ready" interrupt never reaches the host, so firmware command confirmations
 * time out ("8800d80 wifi start fail"). Synchronous SDIO register reads work on
 * this controller. Poll the chip interrupt-status register and drive the same
 * RX handler the interrupt would. Claim the host across the handler call to
 * match the atomicity of the real SDIO IRQ path. */
int aicwf_sdio_busrx_poll_thread(void *data)
{
	struct aicwf_bus *bus_if = (struct aicwf_bus *)data;
	struct aic_sdio_dev *sdiodev = bus_if->bus_priv.sdio;

	while (1) {
		if (kthread_should_stop()) {
			sdio_err("sdio busrx poll thread stop\n");
			break;
		}
		if (bus_if->state == BUS_UP_ST && sdiodev->func) {
			static unsigned int rearm;
			sdio_claim_host(sdiodev->func);
			/* Read the standard SDIO CCCR interrupt registers for FN1 via func0:
			 * IntEnable (0x04) and IntPending (0x05). If post-jump the card sets
			 * IntPending bit1 (FN1 has a frame, the 1038) but the host CARD_INT
			 * never latches, the fault is host PHY/sampling (0x240/0x24c). If
			 * IntPending stays clear, the chip is silent post-jump, which points to
			 * firmware or bring-up. Also log misc for reference. */
			{
				static unsigned int cv_t, cv_l, cv_seen, cv_seen2, cv_seen3;
				if (sdiodev->cv_start_app) {
					/* Passive race probe. After START_APP the loader posts the
					 * 1038 cfm and jumps at once, so misc(0x04) and the CCCR FN1
					 * int-pending line self-clear within microseconds as the fmac
					 * re-inits its SDIO slave. Sample every tick with CMD52 reads
					 * only (no FIFO read, no writes here) and latch the first
					 * nonzero. A hit means the loader posted 1038 and the transport
					 * briefly carried it. No hit across the whole wait means the chip
					 * is silent. The loop delay drops to udelay(2) while cv_start_app
					 * to resolve this microsecond-scale window. */
					int cret = 0;
					u8 cv_ip = sdio_f0_readb(sdiodev->func, 0x05, &cret);
					u8 cv_m = 0;
					aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.misc_int_status_reg, &cv_m);
					if (!cv_seen && (cv_ip & 0x02)) { cv_seen = 1;
						sdio_err("cv18xx RACE-HIT: CCCR_IP FN1 bit1 set misc=0x%02x tick=%u\n", cv_m, cv_t); }
					if (!cv_seen2 && (cv_m == 120 || cv_m == 127)) { cv_seen2 = 1;
						sdio_err("cv18xx RACE-HIT: misc byte-mode=0x%02x CCCR_IP=0x%02x tick=%u\n", cv_m, cv_ip, cv_t); }
					if (!cv_seen3 && cv_m != 0) { cv_seen3 = 1;
						sdio_err("cv18xx post-jump misc FIRST-nonzero=0x%02x CCCR_IP=0x%02x tick=%u\n", cv_m, cv_ip, cv_t); }
					if ((cv_t++ & 0x3FFF) == 0 && cv_l < 12) { cv_l++;
						sdio_err("cv18xx pj tick: CCCR_IP(0x05)=0x%02x misc(0x04)=0x%02x t=%u\n", cv_ip, cv_m, cv_t); }
				} else if ((cv_t++ & 0x3FF) == 0 && cv_l < 200) {
					int cret = 0;
					u8 cv_ien = sdio_f0_readb(sdiodev->func, 0x04, &cret);
					u8 cv_ip = sdio_f0_readb(sdiodev->func, 0x05, &cret);
					u8 cv_cfg = 0, cv_pend = 0, cv_m = 0;
					cv_l++;
					aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.intr_config_reg, &cv_cfg);
					aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.sleep_reg, &cv_pend);
					aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.misc_int_status_reg, &cv_m);
					sdio_err("cv18xx dl: CCCR_IEN=0x%02x CCCR_IP=0x%02x | FN1 cfg(0x00)=0x%02x pend(0x01)=0x%02x misc(0x04)=0x%02x sa=%d st=%d\n",
						cv_ien, cv_ip, cv_cfg, cv_pend, cv_m, sdiodev->cv_start_app, bus_if->state);
				}
			}
			/* The running fmac re-inits its SDIO slave after START_APP. This can
			 * clear the chip-side interrupt-enable (intr_config_reg, written 0x07
			 * at bus_start), so the chip stops posting new cfms and the host
			 * re-reads the stale last upload cfm. Re-assert intr_config_reg
			 * periodically (0x07 is idempotent) so the fmac posts its START_APP
			 * cfm. */
			rearm++;
			if (!sdiodev->cv_start_app) {
				if ((rearm & 0xFF) == 0)
					aicwf_sdio_writeb(sdiodev, sdiodev->sdio_reg.intr_config_reg, 0x07);
			} else {
				/* Post-jump, only observe (diagnostic reads plus the read-driven
				 * hal_irqhandler). Post-START_APP writes (the 0x00 re-arm, the
				 * wakeup, and the byte-mode func1 read that consumes frames) can
				 * disturb the fmac SDIO-slave re-init right after the jump. Leave the
				 * fmac undisturbed so it can post its cfm. */
			}
			/* Force-wake the post-jump fmac. After START_APP the bootrom jumps to
			 * the fmac, which re-inits its SDIO slave and sleeps again. The host
			 * state is still SDIO_ACTIVE_ST (set at send time), so the state-gated
			 * aicwf_sdio_wakeup is a no-op and nothing re-wakes the fmac while the
			 * host waits for the cfm. cmd 1037 then times out ("8800d80 wifi start
			 * fail"), and misc/bytemode read 0 because the SDIO slave is asleep.
			 * Write the D80 wake value (0x11) to wakeup_reg directly (about every 16
			 * ticks) so the fmac stays awake and posts its START_APP cfm. */
			/* Vendor wake handshake (mirrors aicwf_sdio_wakeup). Write wakeup_reg
			 * 0x11, then poll sleep_reg for bit 0x10 (awake), and retry the write
			 * up to 20 times. Log whether the chip confirms awake. Do this about
			 * every 1024 ticks so it repeats across the START_APP wait. If bit 0x10
			 * sets, the fmac is asleep but alive. If it never sets, the fmac is not
			 * running. */
			if (sdiodev->cv_start_app && (rearm & 0x3FF) == 0) {
				int wr, rr; u8 sv = 0; int awake = 0;
				for (wr = 0; wr < 20 && !awake; wr++) {
					aicwf_sdio_writeb(sdiodev, sdiodev->sdio_reg.wakeup_reg, 0x11);
					for (rr = 0; rr < 10; rr++) {
						aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.sleep_reg, &sv);
						if (sv & 0x10) { awake = 1; break; }
						udelay(200);
					}
				}
				sdio_err("cv18xx wake handshake: sleep_reg=0x%02x awake=%d wr=%d\n", sv, awake, wr);
			}
			/* Post-jump fix. The running fmac posts its START_APP cfm (1038) in
			 * byte mode. It writes the frame length to bytemode_len_reg and does
			 * not set misc_int_status. The handler reads byte mode only when
			 * misc==127/120, but misc here is stuck on the stale block-mode upload
			 * cfm (1036), so the byte-mode frame is never read and cmd 1037 times
			 * out. Probe bytemode_len_reg every tick. If the fmac posted a frame,
			 * read it on the func_msg (func2) path and feed it to the RX queue like
			 * the handler 127 byte-mode case does. */
			{
				static unsigned int cv_bm_total, cv_bm_log;
				u8 cv_bl = 0;
				if (sdiodev->cv_start_app && cv_bm_total < 4096) {
					aicwf_sdio_intr_get_len_bytemode(sdiodev, &cv_bl);
					if (cv_bl > 0 && cv_bl <= 128) {
						/* func1: the D80 posts the byte-mode cfm on func1 and has no
					 * func_msg. readframes(sdiodev,1) would claim a NULL func2 and
					 * cause a WARN storm on the wrong function. Read on func1. */
					struct sk_buff *cvpkt = aicwf_sdio_readframes(sdiodev, 0);
						cv_bm_total++;
						if (cvpkt) {
							if (cv_bm_log++ < 80)
								sdio_err("cv18xx BYTEMODE frame: bl=%d len=%d hdr %02x %02x %02x %02x %02x %02x %02x %02x\n",
									cv_bl, cvpkt->len, cvpkt->data[0], cvpkt->data[1], cvpkt->data[2], cvpkt->data[3],
									cvpkt->data[4], cvpkt->data[5], cvpkt->data[6], cvpkt->data[7]);
							aicwf_sdio_enq_rxpkt(sdiodev, cvpkt);
							complete(&bus_if->busrx_trgg);
						}
					}
				}
			}
			if (sdiodev->cv_start_app)
				aicwf_sdio_hal_irqhandler(sdiodev->func);
			sdio_release_host(sdiodev->func);
		}
		/* Sample the post-jump window finer than the IRQ chain. Gate on BUS_UP
		 * so the loop stops busy-spinning once the cmd times out and the bus
		 * goes down. */
		if (bus_if->state == BUS_UP_ST && sdiodev->func && sdiodev->cv_start_app)
			udelay(2);
		else
			usleep_range(30, 80);
	}

	return 0;
}
'''

with open(BSP + "/aicsdio.c", "a") as f:
    f.write(FUNC)

print("aic8800 cv18xx SDIO poll patch applied")

# ===== FDRV post-jump drain =====
# The bsp poll cannot catch the post-jump cfm. The bsp returns right after
# START_APP and releases the SDIO, so the fdrv rwnx_ic_system_init chip_id read
# (DBG_MEM_READ) times out in the FDRV module. The fmac is alive (sleep_reg 0x10)
# and posts its cfm via the INTR_PENDING (0x01) soft-irq (pend=0x11, misc=0x01),
# but asserts no CARD_INT. So make the fdrv busrx thread poll and call its own
# hal_irqhandler, and add a soft-irq/byte-mode fallback to that handler.
FDRV = "src/SDIO/driver_fw/driver/aic8800/aic8800_fdrv"

# A) fdrv busrx thread: replace block-on-CARD_INT with poll (2ms), claim, and
#    call the handler.
patch(
    FDRV + "/aicwf_sdio.c",
    "        if (!wait_for_completion_interruptible(&bus_if->busrx_trgg)) {\n\n            if (bus_if->state == BUS_DOWN_ST)",
    "        wait_for_completion_timeout(&bus_if->busrx_trgg, msecs_to_jiffies(2));\n"
    "        if (bus_if->state == BUS_UP_ST && bus_if->bus_priv.sdio->func) {\n"
    "            struct aic_sdio_dev *_fs = bus_if->bus_priv.sdio;\n"
    "            static unsigned int _fdt; u8 _fm=0,_fp=0,_ic=0,_fc=0,_be=0,_b0=0,_b1=0,_ien=0,_ip=0; int _rr=0;\n"
    "            sdio_claim_host(_fs->func);\n"
    "            aicwf_sdio_readb(_fs, _fs->sdio_reg.misc_int_status_reg, &_fm);\n"
    "            aicwf_sdio_readb(_fs, _fs->sdio_reg.sleep_reg, &_fp);\n"
    "            aicwf_sdio_readb(_fs, _fs->sdio_reg.intr_config_reg, &_ic);\n"
    "            aicwf_sdio_readb(_fs, _fs->sdio_reg.flow_ctrl_reg, &_fc);\n"
    "            aicwf_sdio_readb(_fs, 0x07, &_be);\n"
    "            _b0 = sdio_f0_readb(_fs->func, 0x110, &_rr);\n"
    "            _b1 = sdio_f0_readb(_fs->func, 0x111, &_rr);\n"
    "            _ien = sdio_f0_readb(_fs->func, 0x04, &_rr);\n"
    "            _ip = sdio_f0_readb(_fs->func, 0x05, &_rr);\n"
    "            if ((_fdt++ & 0x3FF) == 0)\n"
    "                sdio_err(\"FDRV pj: misc=%02x pend=%02x cfg=%02x fc=%02x be=%02x blksz=%02x%02x ien=%02x ip=%02x\\n\", _fm, _fp, _ic, _fc, _be, _b1, _b0, _ien, _ip);\n"
    "            /* Anti-storm: when the bus reads dead (0xff = -110 bus error) skip the\n"
    "             * re-arm and handler so a wedged AIC cannot saturate the serial console. */\n"
    "            if (_fm != 0xff) {\n"
    "                /* Re-arm CCCR FN0 int-enable IEN2 (bit2) and dev intr_config every tick */\n"
    "                sdio_f0_writeb(_fs->func, 0x07, 0x04, &_rr);\n"
    "                aicwf_sdio_writeb(_fs, _fs->sdio_reg.intr_config_reg, 0x07);\n"
    "                aicwf_sdio_hal_irqhandler(_fs->func);\n"
    "            }\n"
    "            sdio_release_host(_fs->func);\n"
    "        }\n"
    "        if (1) {\n\n            if (bus_if->state == BUS_DOWN_ST)",
)

# B) fdrv hal_irqhandler D80: when misc==0 but the fmac set the INTR_PENDING
#    soft-irq, read the byte-mode cfm frame directly (the fmac post-jump cfm path).
patch(
    FDRV + "/aicwf_sdio.c",
    "        if (intstatus & SDIO_OTHER_INTERRUPT) {\n"
    "            u8 int_pending;\n"
    "            ret = aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.sleep_reg, &int_pending);",
    "        if (intstatus == 0) {\n"
    "            u8 cvp = 0, cvbl = 0;\n"
    "            aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.sleep_reg, &cvp);\n"
    "            if (cvp & 0x01) {\n"
    "                aicwf_sdio_writeb(sdiodev, sdiodev->sdio_reg.sleep_reg, cvp & ~0x01);\n"
    "                aicwf_sdio_intr_get_len_bytemode(sdiodev, &cvbl);\n"
    "                if (cvbl > 0 && cvbl <= 128) {\n"
    "                    pkt = aicwf_sdio_readframes(sdiodev);\n"
    "                    if (pkt) { aicwf_sdio_enq_rxpkt(sdiodev, pkt); complete(&bus_if->busrx_trgg); pkt = NULL; }\n"
    "                }\n"
    "            }\n"
    "        }\n"
    "        if (intstatus & SDIO_OTHER_INTERRUPT) {\n"
    "            u8 int_pending;\n"
    "            ret = aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.sleep_reg, &int_pending);",
)
print("aic8800 FDRV post-jump drain patch applied")

# C) Skip the fdrv post-jump chip_id DBG_MEM_READ. The running fmac does not
# service the bootrom DBG_MEM_* protocol (the fmac is awake, pend=0x10, but never
# posts a cfm for cmd 1024), so the read times out and crashes the cmd queue
# before MM_RESET is sent. Hardcode chip_id (D80) and let fdrv proceed to
# rwnx_send_reset (MM_RESET, the fmac native cmd), which the fdrv poll drain
# delivers.
patch(
    FDRV + "/rwnx_main.c",
    "\tif (rwnx_send_dbg_mem_read_req(rwnx_hw, mem_addr, &rd_mem_addr_cfm)){\n"
    "\t\treturn -1;\n"
    "    }\n\n"
    "\tchip_id = (u8)(rd_mem_addr_cfm.memdata >> 16);\n\n"
    "    if (rwnx_send_dbg_mem_read_req(rwnx_hw, 0x00000020, &rd_mem_addr_cfm)) {\n"
    "\t\tAICWFDBG(LOGERROR, \"[0x00000020] rd fail\\n\");\n"
    "        return -1;\n"
    "    }\n"
    "    chip_sub_id = (u8)(rd_mem_addr_cfm.memdata);",
    "\tchip_id = 3; chip_sub_id = 0; /* skip post-jump DBG_MEM_READ, use native MM_RESET */",
)
print("aic8800 FDRV chip_id-bypass patch applied")

# D) Flow-control credit bypass. aicwf_sdio_flow_ctrl_msg gates every command send
# on the chip advertised msg-credit reg (flow_ctrl_reg 0x03). If the post-jump
# fmac reports 0 credits (command RX buffers not set up), the command is never
# written and cmd_mgr times out, which looks like the fmac ignores messages. The
# vendor already bypasses this for D80N/D80WN (hardcode return 4). Do the same for
# plain D80: log the real credit value and force >=4 so commands go out.
patch(
    FDRV + "/aicwf_sdio.c",
    "\tif (sdiodev->chipid == PRODUCT_ID_AIC8800D80N ||\n"
    "\t\tsdiodev->chipid == PRODUCT_ID_AIC8800D80WN)\n"
    "\t\treturn 4;\n"
    "\n"
    "    while (true) {\n"
    "        ret = aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.flow_ctrl_reg, &fc_reg);",
    "\tif (sdiodev->chipid == PRODUCT_ID_AIC8800D80N ||\n"
    "\t\tsdiodev->chipid == PRODUCT_ID_AIC8800D80WN)\n"
    "\t\treturn 4;\n"
    "\tif (sdiodev->chipid == PRODUCT_ID_AIC8800D80) {\n"
    "\t\tu8 _fcv = 0; static unsigned int _fcl;\n"
    "\t\taicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.flow_ctrl_reg, &_fcv);\n"
    "\t\tif ((_fcl++ & 0x3F) == 0)\n"
    "\t\t\tsdio_err(\"FDRV msg flowctrl reg=0x%02x\\n\", _fcv);\n"
    "\t\treturn (_fcv > 0) ? _fcv : 4; /* force >=4 msg credits post-jump */\n"
    "\t}\n"
    "\n"
    "    while (true) {\n"
    "        ret = aicwf_sdio_readb(sdiodev, sdiodev->sdio_reg.flow_ctrl_reg, &fc_reg);",
)
print("aic8800 FDRV msg flow-control credit bypass applied")

# E) Re-enumeration fix (disabled). Aims at fc=0x00 (the fmac firmware message
# task does not start post-jump). The vendor forces a full SDIO re-enum between
# the bsp download and fdrv stages (re-run CMD5/CMD3/CMD7/CIS on the chip), which
# makes the fmac firmware finish its boot and start its message task. The
# func-reuse path skips it (rescan calls are behind ALLWINNER/ROCKCHIP/NANOPI
# ifdefs). mmc_sw_reset does a CMD52 I/O-reset (CCCR 0x06=0x08 RES) and
# mmc_sdio_reinit_card without a power cycle (firmware in chip RAM survives). Then
# func_init set_block_size/enable_func/arming re-arms the slave. Inject right after
# `host = ...` and before sdio_claim_host (mmc_sw_reset claims the host itself, so
# no nested claim).
# Disabled: mmc_sw_reset returned -110 (CMD5 fails post-jump).
print("aic8800 FDRV mmc_sw_reset re-enum DISABLED")

# F) Pre-download power-cycle (disabled). Aims to copy the vendor CVITEK fresh
# WL_REG_ON power-cycle just before the fmac download. The DTS mmc-pwrseq raises
# WL_REG_ON once at boot, and the driver downloads much later, so the fmac boots
# from a stale power state, not a fresh power-then-rescan. mmc_hw_reset drives the
# pwrseq (WL_REG_ON off/on) and re-enumerates via the mmc core. Then re-arm
# (aicwf_sdiov3_func_init) and the existing download and jump run on a
# freshly-powered chip.
# Disabled: mmc_hw_reset mid-bring-up hung the SDHCI host permanently. A
# synchronous power-cycle and re-enum from inside the driver probe wedges the
# cv18xx host. The vendor does it non-blocking (WL_REG_ON gpio toggle plus async
# cvi_sdio_rescan), which is the correct approach.
print("aic8800 BSP pre-download mmc_hw_reset power-cycle DISABLED (hung the host)")
