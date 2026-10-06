# TRENDnet TEW-829DRU — OpenWrt 25.12 port

IPQ4019 + QCA9984, QCA8075 + QCA8337 dual switch, 8 MB SPI NOR + 128 MB NAND, stock
U-Boot 2012.07 (QSDK), machid `0x8010006` (AP-DK07.1-C1).

Built on catspeed-cc/openwrt branch `trendnet_tew-829dru-25.12` at `565583d`
(`build/BASE_COMMIT`) plus the six patches in `patches/`.

**Status:** builds and passes all 50 checks in `tools/verify_images.sh` against the real
binaries. **Not yet run on hardware.** Follow `RUNBOOK.md`: RAM boot first, back up, then
install with the UART attached.

## Images (`images/`)

| File | Use |
|---|---|
| `…-initramfs-uImage.itb` | TFTP RAM boot from U-Boot; writes nothing. Start here. |
| `…-squashfs-stock-webui.bin` | Upload from the stock web UI (untick keep settings). Stock writes its inactive slot and flips `boot_partition`. |
| `…-squashfs-sysupgrade.bin` | Install from a running/RAM-booted OpenWrt. |
| `…-psgmii-alt-initramfs-uImage.itb` | RAM boot with the fork's original `psgmii-ethphy` (A/B test for QCA8075 port problems). |
| `…-squashfs-factory.ubi` | Raw UBI for `nand write` from U-Boot (last resort). |
| `…-uImage.itb` | Kernel FIT alone. |

Checksums: `build/SHA256SUMS.kit`. Package list: `build/*.manifest`.

## Rebuild

```sh
git clone -b trendnet_tew-829dru-25.12 https://github.com/catspeed-cc/openwrt.git
cd openwrt && git checkout 565583d
git am /path/to/patches/*.patch
cp /path/to/build/feeds.conf . && ./scripts/feeds update -a && ./scripts/feeds install -a
cp /path/to/build/diffconfig .config && make defconfig
FORCE_UNSAFE_CONFIGURE=1 make -j$(nproc)        # FORCE_UNSAFE only if building as root
tools/verify_images.sh bin/targets/ipq40xx/generic
```
Alternate PSGMII image: apply `tools/psgmii-alt.patch` by hand (one line), `make target/linux/install`.

## Patches

1. Restore the ipqess dual-switch patch the fork's last commit deleted (DTS depends on it).
2. Boot via stock U-Boot: FIT config `config@ap.dk07.1-c1`, U-Boot env config, sysupgrade.
3. DTS fixes from the stock AP-DK07.1-C1 tree: stock NAND layout, reset GPIO34 (polled),
   PSGMII PHY at 0x0d, MACs from ART, no WAN1+WAN2 bridge.
4. Dual-switch driver: use the fork's working revision (2cfa890) instead of 972b3b1.
5. WPS button GPIO18, LED naming/triggers, AR8035 PHY at MDIO 0x06, stock-equivalent packages.
6. Stock web UI image + slot-agnostic A/B (boots whichever slot U-Boot picks; sysupgrade
   writes the other and flips `boot_partition`, like stock).

## What was wrong with the fork

| # | Problem | Evidence |
|---|---|---|
| 1 | Merged all NAND into one 128 MB `rootfs`; stock U-Boot only knows `rootfs`/`rootfs_1`/`overlay` (48/48/32 MB) | U-Boot `smeminfo` (goldsheet), stock flash script |
| 2 | `DEVICE_DTS_CONFIG := config@1`; stock FIT has no `config@1`, U-Boot selects by board name | stock kernel FIT listing, machid→board table |
| 3 | sysupgrade ignored stock A/B (`boot_partition`) | stock `lib/upgrade/platform.sh` |
| 4 | No U-Boot env config, so `fw_setenv` can't work | fork `uboot-envtools` |
| 5 | Last commit deleted the dual-switch driver patch the DTS needs | fork git history |
| 6 | 972b3b1 version: netdev2 ops = block-scope compound literal (dangling), no xmit, no RX demux | fork git history |
| 7 | Based on DK04.1; board is DK07.1-C1 | `machid=8010006`, TRENDnet GPL CDT table |
| 8 | Reset on GPIO18 (DK04 button); real reset is GPIO34 polled; 18 is WPS | stock DK07 DTB, `um_io.sh` |
| 9 | `psgmii-ethphy` pointed at a live port PHY (0x0c); PSGMII PHY is 0x0d | U-Boot `mii info`, base+5 convention |
| 10 | MACs read from U-Boot env keys that don't exist; stock keeps them in ART | `printenv`, stock `setmac` |
| 11 | QCA9984 LED "claimed by qca8k" — it's the radio's own GPIO17 | ath10k-ct hw table |
| 12 | AR8035 PHY at MDIO 0x06 not described | `mii info`, stock `um_switch-phy` |
| 13 | `wan1`+`wan2` bridged into one `br-wan` | fork `02_network` |
| 14 | IMAGE_SIZE for the merged layout | fork `generic.mk` |
| 15 | No WPS (`wpad-basic`), none of stock's dual-WAN/VPN/LTE/SMB packages | stock init.d, modules, LuCI |

Their `spi-extracted.dts` is in modern OpenWrt syntax (their own work, not a raw dump), so
"confirmed by extracted DTS" comments in the fork are partly circular.

What they got right: UART, flash chips, Wi-Fi calibration offsets (match stock),
LED pins 49/45/50, USB power GPIO48, Wi-Fi on both chips, the dual-switch driver approach.

## Stock web UI upgrade format (reverse-engineered)

18-byte ASCII header + FIT:
- `UR_C` + 6-char board id (`053192`; checked against `um_art r bid`, `ffffff` is a wildcard)
  + 8 hex digits CRC-32/MPEG-2 (poly 0x04c11db7, init 0xffffffff, no reflect, no xorout)
  over everything after the header.
- FIT must contain a section named `ubi*` (crc32 hash). Stock `ubiformat`s it onto the slot
  it is not running from and flips `boot_partition`. An `overlay*` section would wipe stock's
  shared overlay; ours has none.
- `tools/tew829-header.py` regenerates the stock v1.0.3.12 image byte-for-byte.

## Still unverified (runbook settles each)

- U-Boot passes `ubi.mtd=<active slot>` to the kernel (NAND boot depends on it).
- `config@ap.dk07.1-c1` is the name `bootipq` asks for.
- MAC order in ART (assumed 0x0 = WAN1, 0x6 = LAN, 0xc = WAN2); the stock hidden page
  `/cgi-bin/luci/j78G-DFdg_24Mhw3.htm` lists the real ones.
- QCA8337 ports through the out-of-tree dual-switch driver (top risk).
- Radio order for LED triggers (phy0 = QCA9984, phy1 = 2.4 GHz, phy2 = 5 GHz).
- No automatic rollback (stock has none either); recovery is `setenv boot_partition` over UART.

## Layout

- `RUNBOOK.md` — UART smoke-test and install procedure
- `patches/` — the six commits (`git am`)
- `tools/` — image verifier, stock header tool, PSGMII alt patch
- `build/` — base commit, feeds.conf, diffconfig, manifest, checksums
- `research/stock-dtb/` — decompiled stock DTBs (DK07.1-C1 is the one U-Boot uses)
- `research/stock-firmware/` — FIT listings of the stock upgrade image and kernel
- `research/stock-scripts/` — TRENDnet/QSDK scripts the findings cite
- `research/community/` — catspeed-cc goldsheet, their extracted DTS, the fork's original DTS (GPLv2)
