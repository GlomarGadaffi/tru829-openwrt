#!/bin/bash
# Post-build checks for the TEW-829DRU smoke-test images.
# usage: verify_images.sh <openwrt bin/targets/ipq40xx/generic dir>
set -u
D=${1:?bin dir}
W=$(mktemp -d)
fail=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

INITRAMFS=$(ls "$D"/*tew-829dru*initramfs*.itb 2>/dev/null | head -1)
FACTORY=$(ls "$D"/*tew-829dru*factory.ubi 2>/dev/null | head -1)
SYSUP=$(ls "$D"/*tew-829dru*sysupgrade.bin 2>/dev/null | head -1)
WEBUI=$(ls "$D"/*tew-829dru*stock-webui.bin 2>/dev/null | head -1)
echo "initramfs:  ${INITRAMFS:-MISSING}"
echo "factory:    ${FACTORY:-MISSING}"
echo "sysupgrade: ${SYSUP:-MISSING}"
echo "webui:      ${WEBUI:-MISSING}"
[ -n "$INITRAMFS" ] && [ -n "$FACTORY" ] && [ -n "$SYSUP" ] || { echo "missing images"; exit 1; }

check_fit() { # $1 = FIT file, $2 = label
	local f=$1 l=$2
	echo "[$l] FIT"
	dumpimage -l "$f" > "$W/$l.fit" 2>&1
	grep -q "Configuration 0 (config@ap.dk07.1-c1)" "$W/$l.fit" \
		&& ok "config@ap.dk07.1-c1 present" || bad "config@ap.dk07.1-c1 missing"
	grep -q "Default Configuration: 'config@ap.dk07.1-c1'" "$W/$l.fit" \
		&& ok "default config is config@ap.dk07.1-c1" || bad "default config wrong"
	local idx
	idx=$(awk '/^ Image [0-9]+ \(fdt/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$W/$l.fit")
	dumpimage -T flat_dt -p "$idx" -o "$W/$l.dtb" "$f" >/dev/null 2>&1
	dtc -I dtb -O dts "$W/$l.dtb" > "$W/$l.dts" 2>/dev/null
	check_dts "$W/$l.dts" "$l"
}

check_dts() { # $1 = dts, $2 = label
	local t=$1 l=$2
	echo "[$l] DTB"
	grep -q 'model = "TRENDnet TEW-829DRU"' "$t" && ok "model" || bad "model"
	grep -q 'bootargs-append = " root=/dev/ubiblock0_1"' "$t" \
		&& ok "bootargs-append" || bad "bootargs-append"
	# NAND partitions
	for p in 'partition@0 {:rootfs:0x00 0x3000000' 'partition@3000000 {:rootfs_1:0x3000000 0x3000000' \
		 'partition@6000000 {:overlay:0x6000000 0x2000000'; do
		IFS=: read -r node label reg <<<"$p"
		awk -v n="$node" -v lb="$label" -v r="$reg" '
			index($0,n){f=1} f&&/label/{ if(index($0,"\"" lb "\"")) L=1 }
			f&&/reg =/{ if(index($0,r)) R=1 } f&&/};/{ if(L&&R){found=1} f=0;L=0;R=0 }
			END{exit !found}' "$t" && ok "nand $label @ $reg" || bad "nand $label"
	done
	grep -A3 'partition@3000000' "$t" | grep -q 'read-only' && bad "rootfs_1 read-only (A/B needs it writable)" || ok "rootfs_1 writable (A/B)"
	grep -A3 'partition@6000000' "$t" | grep -q 'read-only' && ok "overlay (stock) read-only" || bad "overlay writable"
	grep -q 'gpio-keys-polled' "$t" && ok "polled keys" || bad "polled keys"
	grep -A6 'reset {' "$t" | grep -q 'gpios = <0x[0-9a-f]* 0x22 0x01>' && ok "reset GPIO34 active-low" || bad "reset GPIO"
	grep -A6 'wps {' "$t" | grep -q 'gpios = <0x[0-9a-f]* 0x12 0x01>' && ok "wps GPIO18 active-low" || bad "wps GPIO"
	grep -A6 'wps {' "$t" | grep -q 'linux,code = <0x211>' && ok "wps KEY_WPS_BUTTON" || bad "wps keycode"
	for g in 0x31 0x2d 0x32; do grep -A4 'led-[0-9] {' "$t" | grep -q "gpios = <0x[0-9a-f]* $g 0x01>" && ok "led gpio $g" || bad "led gpio $g"; done
	grep -q 'ethernet-phy@6 {' "$t" && ok "AR8035 phy@6 described" || bad "phy@6"
	grep -B1 -A2 'psgmii-phy@d' "$t" | grep -q 'reg = <0x0d>' && ok "psgmii-phy@d reg 0xd" || bad "psgmii phy node"
	grep -q 'psgmii-ethphy' "$t" && ok "psgmii-ethphy set" || bad "psgmii-ethphy"
	grep -q 'qcom,dual-switch' "$t" && ok "dual-switch flag" || bad "dual-switch flag"
	grep -q 'macaddr@6' "$t" && grep -q 'macaddr@c' "$t" && ok "ART mac cells" || bad "ART mac cells"
}

check_fit "$INITRAMFS" initramfs

echo "[factory] UBI"
ubireader_display_info "$FACTORY" > "$W/ubi.txt" 2>&1
for v in kernel rootfs; do
	grep -q "Volume Name:$v\$" "$W/ubi.txt" && ok "volume $v" || bad "volume $v"
done
grep -q "PEB Size: 131072" "$W/ubi.txt" && ok "PEB 128 KiB" || bad "PEB size"
sz=$(stat -c %s "$FACTORY")
[ "$sz" -lt $((48*1024*1024)) ] && ok "factory.ubi $sz B < 48 MiB rootfs" || bad "factory.ubi too big ($sz)"
mkdir -p "$W/ubi"; ubireader_extract_images -o "$W/ubi" "$FACTORY" >/dev/null 2>&1
K=$(ls "$W"/ubi/*/*vol-kernel* 2>/dev/null | head -1)
[ -n "$K" ] && check_fit "$K" nand-kernel || bad "could not extract kernel volume"

echo "[sysupgrade]"
tar tf "$SYSUP" > "$W/sys.txt" 2>/dev/null
grep -q 'sysupgrade-trendnet_tew-829dru/kernel' "$W/sys.txt" && grep -q 'sysupgrade-trendnet_tew-829dru/root' "$W/sys.txt" \
	&& ok "tar has kernel+root" || bad "sysupgrade tar layout: $(tr '\n' ' ' < "$W/sys.txt")"

echo "[stock-webui]"
if [ -n "$WEBUI" ]; then
	python3 -I - "$WEBUI" "$FACTORY" "$W" <<'PY' && ok "header magic/board id/CRC-32/MPEG-2 valid" || bad "webui header"
import sys
d=open(sys.argv[1],'rb').read(); h,body=d[:18],d[18:]
T=[]
for i in range(256):
    c=i<<24
    for _ in range(8): c=(((c<<1)^0x04c11db7) if c&0x80000000 else (c<<1))&0xffffffff
    T.append(c)
c=0xffffffff
for b in body: c=((c<<8)&0xffffffff)^T[((c>>24)^b)&0xff]
assert h[:4]==b'UR_C' and h[4:10]==b'053192' and h[10:]==b'%08x'%c, h
open(sys.argv[3]+'/webui.itb','wb').write(body)
PY
	dumpimage -l "$W/webui.itb" > "$W/webui.txt" 2>&1
	grep -q '^ Image 0 (ubi' "$W/webui.txt" && ok "FIT has ubi* section (stock mandatory)" || bad "no ubi section"
	grep -q 'Hash algo:    crc32' "$W/webui.txt" && ok "crc32 hash node (stock dumpimage -c)" || bad "hash node"
	grep -q '(overlay' "$W/webui.txt" && bad "overlay section present (would wipe stock overlay)" || ok "no overlay section"
	dumpimage -T flat_dt -p 0 -o "$W/webui.ubi" "$W/webui.itb" >/dev/null 2>&1
	cmp -s "$W/webui.ubi" "$FACTORY" && ok "payload == factory.ubi" || bad "payload differs from factory.ubi"
	sz=$(stat -c %s "$W/webui.ubi"); [ "$sz" -lt $((48*1024*1024)) ] && ok "payload fits 48 MiB slot" || bad "payload too big"
else
	bad "stock-webui.bin missing"
fi

echo; [ $fail = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
rm -rf "$W"
exit $fail
