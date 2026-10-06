# TEW-829DRU OpenWrt smoke test — UART runbook

Build: catspeed-cc/openwrt `trendnet_tew-829dru-25.12` + local branch `smoke/tew829dru-fixes`
(tree at `/home/user/tew829/openwrt`). Nothing here writes flash until Phase 5.

Images (names as produced by the build; `verify_images.sh` confirms them):

| File | Use |
|---|---|
| `openwrt-ipq40xx-generic-trendnet_tew-829dru-initramfs-uImage.itb` | RAM boot over TFTP. Flash untouched. |
| `openwrt-ipq40xx-generic-trendnet_tew-829dru-squashfs-sysupgrade.bin` | Install from the RAM-booted system (`sysupgrade -n`). |
| `openwrt-ipq40xx-generic-trendnet_tew-829dru-squashfs-factory.ubi` | Raw UBI for `nand write` from U-Boot (fallback install path). |
| `openwrt-ipq40xx-generic-trendnet_tew-829dru-squashfs-stock-webui.bin` | Upload from the **stock** web UI (System → Firmware upgrade). Stock writes it to its inactive slot and flips `boot_partition`; stock stays in the other slot. |

## 0. Bench setup

- UART header: 4-pin, behind the heatsink, next to the 8-pin SPI NOR. Pin 1 (hollow
  triangle, leftmost with ports facing you) = 3.3 V, 2 = GND, 3 = TX, 4 = RX. 3.3 V logic;
  do **not** connect pin 1 to your adapter. 115200 8N1.
- Stock U-Boot env expects a TFTP server at **192.168.10.100**; the board takes
  **192.168.10.11**. Put the host on 192.168.10.100/24, TFTP root with the three images.
  U-Boot talks through `eth0` = **WAN1** in stock's numbering; if `tftpboot` times out, try
  the other WAN jack, then LAN ports.
- Before touching the bootloader, from the running **stock** UI, open
  `http://<router>/cgi-bin/luci/j78G-DFdg_24Mhw3.htm` (hidden engineering page) and record:
  LAN/WAN1/WAN2 MACs, the three WLAN MACs, the three country codes, serial, board ID.
  These are the ground truth for the MAC/ART checks below.

## 1. U-Boot: read-only reconnaissance

Interrupt autoboot (any key within `bootdelay=7`). Capture everything to a log.

```
version
printenv
smeminfo
sf probe
nand info
nand bad
mii info
pci
```

Expect `machid=8010006`, `boot_partition=0|1`, flash parts `rootfs 0x0 0x3000000`,
`rootfs_1 0x3000000 0x3000000`, `overlay 0x6000000 0x2000000`.
**Record `boot_partition`** — it tells you which slot stock is running from. Any install
(stock web UI or OpenWrt sysupgrade) writes the *other* slot, so the slot you see here
keeps stock as the fallback.

Optional, settles the FIT config question before any boot: `help bootipq` and
`printenv bootcmd`. If `bootipq` is a script, `printenv` shows how it builds the
`config@...` name.

## 2. RAM boot (no flash writes)

```
setenv ipaddr 192.168.10.11
setenv serverip 192.168.10.100
tftpboot 0x84000000 openwrt-ipq40xx-generic-trendnet_tew-829dru-initramfs-uImage.itb
bootm 0x84000000#config@ap.dk07.1-c1
```

If U-Boot complains about the config name, retry with plain `bootm 0x84000000`
(default config) and note which one worked — that decides whether `DEVICE_DTS_CONFIG`
is right.

Watch the console for: `Machine model: TRENDnet TEW-829DRU`, UBI attaching, `ipqess`,
`qca8k`, `ath10k` lines. A hang after "Starting kernel" with no output = DTS/console
problem; power-cycle, nothing was written.

## 3. In the RAM-booted system

Console login is root/no password. Save all output (`logread`, `dmesg`) to the host:
`dmesg > /tmp/dmesg.txt; tftp -p -l /tmp/dmesg.txt -r tew-dmesg.txt 192.168.10.100`.

### 3a. Partitions and boot path

The NAND image relies on stock U-Boot passing `ubi.mtd=<active slot>`; a RAM boot via
`bootm` does not show that, so read it out of the bootloader itself:
```
dd if=/dev/mtd6 2>/dev/null | strings | grep -E 'ubi\.mtd|root=|rootfsname|boot_partition|config@' | sort -u
```
Expect something like `ubi.mtd=%s` / `root=mtd:ubi_rootfs` / `boot_partition`. If there
is **no** `ubi.mtd`, stop before Phase 5: the NAND image would not find its root.

```
cat /proc/cmdline                 # RAM boot: just root=/dev/ubiblock0_1 appended
cat /proc/mtd                     # 11 parts: SBL1..ART, rootfs, rootfs_1, overlay
ubinfo -a                         # which UBI devices attached, volume names
ubiattach -m $(grep -w rootfs_1 /proc/mtd | cut -c4) ; ubinfo -a   # stock slot: kernel + ubi_rootfs present?
```
**Gate for Phase 5:** `rootfs_1` (or `rootfs`, whichever is NOT the current
`boot_partition`) must contain a healthy stock `kernel`/`ubi_rootfs` pair. That is your
fallback.

### 3b. ART / MAC ground truth

```
dd if=/dev/mtd7 bs=64 count=1 2>/dev/null | hexdump -C      # mtd7 = ART (check /proc/mtd)
ip -br link | grep -E 'wan|lan|eth'
```
Compare the first 0x12 bytes with the MACs from step 0: expected layout 0x0 = WAN1,
0x6 = LAN, 0xc = WAN2. If the order differs, note which offset holds which MAC
(fix lands in `02_network`). `wan1` and `br-lan` should carry those MACs.

### 3c. Ethernet (the main unknown)

```
ls /sys/class/net
dmesg | grep -iE 'qca8k|ipqess|psgmii|mdio|phy'
for p in wan1 wan2 lan1 lan2 lan3 lan4 lan5 lan6 lan7 lan8; do echo "$p $(cat /sys/class/net/$p/operstate 2>&1)"; done
```
Then a cable, one jack at a time, from a laptop at 192.168.1.2:
- which netdev goes `up` (and which **jack** it is — write the physical mapping down;
  the fork's labels are unverified),
- `ping 192.168.1.1` from the laptop,
- `ethtool <port>` link speed.

Do the five QCA8337 ports (`lan1 lan3 lan4 lan5 lan6` per the DTS) as a separate group.
If none of them pass traffic while link is up: `ip -d link show eth1`,
`ethtool -S eth0 | grep -i port`, `dmesg | grep -i 'dsa\|8337'`. That is the dual-switch
patch not demuxing — expected risk, and the data we need.

PSGMII sanity (QCA8075 ports): if `wan1 wan2 lan2 lan7 lan8` link but drop packets or
show errors in `ethtool -S`, re-test with the alternate image
(`openwrt-ipq40xx-generic-trendnet_tew-829dru-psgmii-alt-initramfs-uImage.itb`) that uses the fork's original `psgmii-ethphy`.

### 3d. Wi-Fi

```
iw dev; iw phy | grep -E 'Wiphy|MHz' | head
ls /sys/class/ieee80211/*/device        # which phy is PCIe (QCA9984) vs AHB
```
Expect three radios. Note phyN ↔ band; `01_leds` assumes phy0 = QCA9984,
phy1 = 2.4 GHz, phy2 = 5 GHz (IPQ4019). Enable one AP per radio and connect.

### 3e. LEDs, buttons, USB, misc

```
ls /sys/class/leds                      # blue:wlan-2ghz blue:wlan-5ghz blue:wps ath10k-phy0
for l in /sys/class/leds/*; do echo 1 > $l/brightness; sleep 1; echo 0 > $l/brightness; done
logread -f &                            # press WPS (expect KEY_WPS_BUTTON), then reset briefly
cat /sys/kernel/debug/gpio
lsusb; dmesg | tail                     # plug a USB stick; expect usb-storage + mount
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null || echo "no thermal (expected)"
ubus call system board
```
Reset button: a short press only logs; holding >5 s in a *flashed* system triggers
factory reset, so keep it short here.

### 3f. Backup everything (still RAM-booted, flash untouched)

```
fw_printenv > /tmp/uboot-env.txt
for i in 0 1 2 3 4 5 6 7; do dd if=/dev/mtd$i of=/tmp/mtd$i.bin; done        # SPI NOR parts
for n in rootfs rootfs_1 overlay; do
  i=$(grep -w "\"$n\"" /proc/mtd | cut -d: -f1 | tr -d mtd)
  nanddump --bb=skipbad -o -f /tmp/nand-$n.bin /dev/mtd$i && \
  tftp -p -l /tmp/nand-$n.bin -r tew-nand-$n.bin 192.168.10.100 && rm /tmp/nand-$n.bin
done
for f in /tmp/mtd*.bin /tmp/uboot-env.txt; do tftp -p -l $f -r tew-$(basename $f) 192.168.10.100; done
```
`mtd7.bin` (ART) is the one you cannot regenerate. Keep two copies.

## 4. Decision point

Install only if **all** of: kernel boots from the right config, `/proc/mtd` matches,
MACs read correctly from ART, at least the QCA8075 ports pass traffic, all three radios
appear, and the stock fallback slot checked out in 3a. Anything else: collect logs, stop.

## 5. Install (writes the inactive slot only)

Keep the UART console attached for the first install on this unit.

**A — stock web UI (the path end users will take):** boot stock normally, System →
Firmware Upgrade, choose `...-squashfs-stock-webui.bin`, **untick "keep settings"**.
Stock strips/checks the header, `ubiformat`s the OpenWrt UBI onto the slot it is *not*
running from, flips `boot_partition`, reboots. Watch the console: U-Boot should load
`kernel` from that slot and pick `config@ap.dk07.1-c1`.

**B — from the RAM-booted OpenWrt:**
```
tftp -g -l /tmp/sys.bin -r openwrt-ipq40xx-generic-trendnet_tew-829dru-squashfs-sysupgrade.bin 192.168.10.100
sysupgrade -n /tmp/sys.bin
```
RAM boot has no `ubi.mtd`, so it falls back to `fw_printenv boot_partition`, writes the
other slot, flips the variable.

**C — U-Boot, raw (only if A and B both refuse).** Write the slot stock is *not* on:
```
tftpboot 0x84000000 openwrt-ipq40xx-generic-trendnet_tew-829dru-squashfs-factory.ubi
# stock on rootfs_1 (boot_partition=1): write rootfs
nand erase 0x0 0x3000000 ; nand write 0x84000000 0x0 ${filesize} ; setenv boot_partition 0
# stock on rootfs   (boot_partition=0): write rootfs_1
nand erase 0x3000000 0x3000000 ; nand write 0x84000000 0x3000000 ${filesize} ; setenv boot_partition 1
saveenv ; reset
```

First boot creates `rootfs_data` inside that slot's UBI; give it a minute. Later OpenWrt
sysupgrades alternate slots like stock did, so the previous firmware is always the
fallback (the first one overwrites stock).

## 6. Recovery

- Back to the other slot (stock, after the first install): U-Boot →
  `setenv boot_partition <other>; saveenv; reset`. Stock's shared `overlay` partition still
  holds its config. There is no automatic rollback — stock never had one either.
- Anything else: TFTP RAM boot from Phase 2 always works as long as U-Boot runs.
- Restore a NAND slot: U-Boot `tftpboot 0x84000000 tew-nand-rootfs_1.bin; nand erase
  0x3000000 0x3000000; nand write 0x84000000 0x3000000 ${filesize}`.

## 7. What each result tells us

| Observation | Meaning / next change |
|---|---|
| `bootm ...#config@ap.dk07.1-c1` fails, plain `bootm` works | drop `DEVICE_DTS_CONFIG` override |
| MAC order in ART differs from 0x0/0x6/0xc = WAN1/LAN/WAN2 | adjust `02_network` offsets |
| QCA8337 ports link but no traffic | dual-switch patch demux wrong; capture `ethtool -S` + `ip -d link` |
| QCA8075 ports flaky, alt image fine | revert `psgmii-ethphy` to `ethphy12` |
| LED follows the wrong radio | swap `phy1tpt`/`phy2tpt` in `01_leds` |
| WPS press logs nothing | GPIO18 polarity or not the button; check `cat /sys/kernel/debug/gpio` while pressed |
| Stock UI rejects the .bin | capture the message; `um_handle_header` failing = board ID differs (`um_art r bid` on the hidden page) |
| NAND boot: "VFS: unable to mount root" | U-Boot passes no/odd `ubi.mtd`; recover via `boot_partition`, send the APPSBL `strings` output |
