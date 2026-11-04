#!/usr/bin/env bash
# stackctl.sh — kontrol stack LTE simulasi (Open5GS EPC + srsRAN eNB/UE via ZMQ) untuk FALCON.
# Aksi TETAP (tidak menerima perintah bebas):  status | up | capture | down
#   status  : JSON ringkas kondisi stack (dipakai backend)
#   up      : nyalakan kontainer + daemon, tunggu UE attach (idempoten)
#   capture : bangkitkan trafik dari UE, tangkap GTP-U S1-U ke $PCAP (ditulis atomik)
#   down    : hentikan UE/eNB/EPC + kontainer (Mongo dibiarkan: hanya data subscriber)
# Env: FALCON_STACK_DIR (default /data/yayang/falcon-5g)  FALCON_STACK_IF (default enp2s0)
set -u
D="${FALCON_STACK_DIR:-/data/yayang/falcon-5g}"
IFACE="${FALCON_STACK_IF:-enp2s0}"
PCAP="$D/pcap/stack-lte.pcap"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DK="sudo -n docker"
B=/open5gs/install/bin; C=/open5gs/install/etc/open5gs
LOCK="$D/.stackctl.lock"

log() { echo "[stackctl] $*" >&2; }
running() { $DK exec "$1" pgrep -x "$2" >/dev/null 2>&1; }

ue_ip() {
  $DK exec falcon_enb sh -c 'ip netns exec ue1 ip -4 -br addr show tun_srsue 2>/dev/null' | awk '{print $3}' | cut -d/ -f1
}

status() {
  python3 - "$D" "$PCAP" <<'PY'
import json, os, subprocess, sys, time
d, pcap = sys.argv[1], sys.argv[2]
def sh(c):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=12).stdout.strip()
    except Exception: return ""
names = ["falcon_mongo", "falcon_epc", "falcon_enb", "falcon_ue"]
up = sh("sudo -n docker ps --format '{{.Names}}' --filter name=falcon_").split()
cont = [{"name": n, "up": n in up} for n in names]
def pg(c, p): return sh("sudo -n docker exec %s pgrep -x %s" % (c, p)) != ""
epc = {p: pg("falcon_epc", "open5gs-" + p) for p in ("hssd","pcrfd","upfd","smfd","sgwud","sgwcd","mmed")} if "falcon_epc" in up else {}
enb = "falcon_enb" in up and pg("falcon_enb", "srsenb")
ue_run = "falcon_enb" in up and pg("falcon_enb", "srsue")
ip = sh("sudo -n docker exec falcon_enb sh -c 'ip netns exec ue1 ip -4 -br addr show tun_srsue 2>/dev/null'") if enb else ""
ip = ip.split()[2].split("/")[0] if len(ip.split()) >= 3 else ""
cap = None
if os.path.exists(pcap):
    st = os.stat(pcap)
    n = sh("tcpdump -nn -r %s 2>/dev/null | wc -l" % pcap)
    cap = {"packets": int(n or 0), "bytes": st.st_size, "age_s": int(time.time() - st.st_mtime)}
if all(epc.values()) and epc and enb and ue_run and ip: state = "running"
elif any(c["up"] for c in cont) or any(epc.values()) or enb or ue_run: state = "partial"
else: state = "stopped"
print(json.dumps({"state": state, "containers": cont, "epc": epc, "enb": enb, "ue": ue_run,
                  "ue_ip": ip, "capture": cap}))
PY
}

wait_for() { # wait_for <detik> <perintah...>
  local t=$1; shift
  for _ in $(seq 1 "$t"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1
}

up() {
  log "kontainer"
  ( cd "$D" && $DK docker compose version >/dev/null 2>&1 ) # no-op, hanya memastikan sudo docker ada
  ( cd "$D" && $DK compose start falcon_mongo falcon_epc falcon_enb falcon_ue 2>&1 | grep -v obsolete ) >&2 || true
  wait_for 20 $DK exec falcon_mongo mongo --quiet --eval 'db.runCommand({ping:1}).ok' || { log "Mongo gagal"; return 1; }
  $DK exec falcon_epc mkdir -p /open5gs/install/var/log/open5gs
  for p in hssd pcrfd upfd smfd sgwud sgwcd mmed; do
    y=${p%d}; [ "$y" = "hss" ] && y=hss
    if ! running falcon_epc "open5gs-$p"; then
      log "mulai open5gs-$p"
      $DK exec -d falcon_epc $B/open5gs-$p -c $C/$y.yaml
      sleep 2
    fi
  done
  if ! running falcon_enb srsenb; then
    log "mulai srsenb"
    $DK exec -d falcon_enb sh -c "cd /srsran/build/srsenb/src && ./srsenb /etc/srsran/enb.conf --log.filename=/tmp/enb.log --log.all_level=warning > /tmp/enb.out 2>&1"
    wait_for 25 $DK exec falcon_enb sh -c 'grep -q "eNodeB started" /tmp/enb.out' || { log "eNB gagal start"; return 1; }
    sleep 3
  fi
  if running falcon_enb srsue && [ -z "$(ue_ip)" ]; then
    log "srsue hidup tanpa IP/TUN (netns rusak) -> mulai ulang eNB + UE agar state sesi bersih"
    $DK exec falcon_enb sh -c 'pkill -9 srsue; pkill -9 srsenb; sleep 2' 2>/dev/null
    $DK exec -d falcon_enb sh -c "cd /srsran/build/srsenb/src && ./srsenb /etc/srsran/enb.conf --log.filename=/tmp/enb.log --log.all_level=warning > /tmp/enb.out 2>&1"
    wait_for 25 $DK exec falcon_enb sh -c 'grep -q "eNodeB started" /tmp/enb.out' || { log "eNB gagal start ulang"; return 1; }
    sleep 3
  fi
  if ! running falcon_enb srsue; then
    log "mulai srsue"
    # netns lama bisa rusak setelah kontainer dimatikan/dinyalakan ("Peer netns reference is invalid"),
    # lalu srsue gagal membuat TUN. Selalu buat ulang dari nol.
    $DK exec falcon_enb sh -c 'ip netns del ue1 2>/dev/null; ip netns add ue1'
    $DK exec falcon_enb sh -c 'rm -f /tmp/ue.out'
    $DK exec -d falcon_enb sh -c "cd /srsran/build/srsue/src && ./srsue /etc/srsran/ue.conf --log.filename=/tmp/ue.log --log.all_level=warning --log.nas_level=info > /tmp/ue.out 2>&1"
  fi
  wait_for 60 $DK exec falcon_enb sh -c 'grep -q "Network attach successful" /tmp/ue.out' || { log "UE belum attach"; return 1; }
  # attach di core saja belum cukup: interface TUN di netns juga harus ada, kalau tidak capture tak punya IP UE
  wait_for 15 $DK exec falcon_enb sh -c 'ip netns exec ue1 ip -4 -br addr show tun_srsue 2>/dev/null | grep -q "[0-9]\\."' \
    || { log "attach OK tapi tun_srsue tidak terbentuk"; return 1; }
  log "UE attach IP $(ue_ip)"
}

capture() {
  local secs=${1:-12} pps=${2:-120}
  local ip; ip="$(ue_ip)"; [ -n "$ip" ] || { log "UE belum attach (jalankan up)"; return 1; }
  mkdir -p "$D/pcap"
  local tmp="$D/pcap/.cap.$$.pcap"
  $DK cp "$HERE/ue_traffic.pl" falcon_enb:/tmp/ue_traffic.pl
  # -Z root: jangan turun ke user 'tcpdump' (file jadi milik tcpdump & tak bisa dipindah). timeout = pengaman.
  sudo -n timeout $((secs+15)) tcpdump -Z root -i "$IFACE" -nn -U -w "$tmp" \
      "udp port 2152 and host 192.168.0.131 and host 192.168.0.130" >/dev/null 2>&1 &
  local tp=$!
  sleep 2
  $DK exec falcon_enb sh -c "ip netns exec ue1 perl /tmp/ue_traffic.pl $((secs*pps)) $pps" >&2
  sleep 2
  # hentikan tcpdump yang ditulis ke $tmp (sudo/timeout membungkusnya, jadi cari lewat pola argumen)
  sudo -n pkill -INT -f "tcpdump -Z root .* -w $tmp" 2>/dev/null
  wait "$tp" 2>/dev/null
  sudo -n chown "$(id -un)":"$(id -gn)" "$tmp" 2>/dev/null
  local n; n=$(tcpdump -nn -r "$tmp" 2>/dev/null | wc -l)
  if [ "${n:-0}" -lt 10 ]; then log "tangkapan kosong ($n paket)"; sudo -n rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$PCAP" || { log "gagal memindahkan pcap"; return 1; }
  log "tangkapan $n paket -> $PCAP"
}

down() {
  $DK exec falcon_enb sh -c 'pkill -9 srsue; pkill -9 srsenb' 2>/dev/null
  $DK exec falcon_epc sh -c 'pkill -9 -f open5gs-' 2>/dev/null
  ( cd "$D" && $DK compose stop falcon_ue falcon_enb falcon_epc 2>&1 | grep -v obsolete ) >&2 || true
}

exec 9>"$LOCK"
case "${1:-}" in
  status)  status ;;
  up)      flock -n 9 || { log "operasi lain berjalan"; exit 3; }; up ;;
  capture) flock -n 9 || { log "operasi lain berjalan"; exit 3; }; shift; capture "$@" ;;
  down)    flock -n 9 || { log "operasi lain berjalan"; exit 3; }; down ;;
  *) echo "pakai: stackctl.sh status|up|capture [detik pps]|down" >&2; exit 2 ;;
esac
