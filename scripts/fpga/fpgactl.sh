#!/usr/bin/env bash
# fpgactl.sh — muat ulang gateware FALCON ke papan Genesys lewat JTAG (iMPACT). Aksi TETAP:
#   status : JSON — kabel JTAG, chip terdeteksi, hash bitstream aktif, link ethernet
#   load   : program bitstream tetap ke papan, set ulang IP host, verifikasi telemetri
# Sengaja TIDAK menerima nama berkas/perintah dari luar. Bitstream = $FALCON_BIT (bawaan di bawah).
# Memakai iMPACT (bukan xc3sprog): xc3sprog pernah membuat TX papan bisu (lihat skill falcon-fpga-gateware).
set -u
BIT="${FALCON_BIT:-/data/yayang/falcon-bitstream/genesys_fpga.bit}"
SHIM="${FALCON_USB_SHIM:-/data/xilinx/xilinx-usb-driver/libusb-driver.so}"
ISE="${FALCON_ISE:-/data/xilinx/14.7/ISE_DS}"
IFACE="${FALCON_STACK_IF:-enp2s0}"
HOSTIP="${FALCON_HOST_IP:-192.168.0.101/24}"
BOARD="${FALCON_BOARD_IP:-192.168.0.20}"
LOCK="/tmp/fpgactl.lock"
log() { echo "[fpgactl] $*" >&2; }

status() {
  python3 - "$BIT" "$IFACE" "$BOARD" <<'PY'
import hashlib, json, os, subprocess, sys
bit, iface, board = sys.argv[1:4]
def sh(c):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception: return ""
usb = "03fd:0008" in sh("lsusb")
link = "yes" in sh("ethtool %s 2>/dev/null | grep 'Link detected'" % iface)
ip = bool(sh("ip -4 -br addr show %s | grep -E '192\\.168\\.0\\.101'" % iface))
sha = ""
if os.path.exists(bit): sha = hashlib.sha256(open(bit, "rb").read()).hexdigest()[:8]
print(json.dumps({"jtag_cable": usb, "eth_link": link, "host_ip": ip, "bitstream": bit if sha else "",
                  "bitstream_sha": sha, "board_ip": board}))
PY
}

load() {
  [ -f "$BIT" ] || { log "bitstream tidak ada: $BIT"; return 2; }
  lsusb | grep -q "03fd:0008" || { log "kabel JTAG (Platform Cable USB II) tidak terdeteksi"; return 3; }
  [ -f "$SHIM" ] || { log "shim libusb tidak ada: $SHIM"; return 4; }
  local W; W=$(mktemp -d /tmp/fpgactl.XXXXXX)
  cat > "$W/flash.cmd" <<EOF
setMode -bscan
setCable -port auto
addDevice -p 1 -file $BIT
program -p 1
quit
EOF
  log "program $(sha256sum "$BIT" | cut -c1-8) lewat iMPACT"
  ( cd "$W" && LD_PRELOAD="$SHIM" bash -c "source $ISE/settings64.sh >/dev/null 2>&1; impact -batch flash.cmd" ) > "$W/impact.log" 2>&1
  local rc=$?
  if ! grep -q "Programmed successfully" "$W/impact.log"; then
    log "iMPACT gagal (rc=$rc):"; tail -5 "$W/impact.log" >&2; rm -rf "$W"; return 5
  fi
  grep -q "Checking done pin" "$W/impact.log" && log "DONE pin OK"
  rm -rf "$W"
  # flash sering membuang IP NIC; pasang ulang (idempoten)
  ip -4 addr show "$IFACE" | grep -q "192.168.0.101" || sudo -n ip addr add "$HOSTIP" dev "$IFACE" 2>/dev/null
  sudo -n ip link set "$IFACE" up 2>/dev/null
  log "tunggu telemetri papan (maks 25 dtk)"
  for _ in $(seq 1 25); do
    sudo -n timeout 2 tcpdump -i "$IFACE" -nn -c 1 "src host $BOARD and udp port 50000" >/dev/null 2>&1 && { log "telemetri masuk"; return 0; }
  done
  log "bitstream terprogram tapi telemetri belum terlihat (cek kabel ethernet / cold boot PHY)"
  return 6
}

exec 9>"$LOCK"
case "${1:-}" in
  status) status ;;
  load)   flock -n 9 || { log "operasi lain berjalan"; exit 9; }; load ;;
  *) echo "pakai: fpgactl.sh status|load" >&2; exit 2 ;;
esac
