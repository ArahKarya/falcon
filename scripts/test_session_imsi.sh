#!/usr/bin/env bash
# Uji KPI sesi turunan + label IMSI simulasi. Backend sementara; "papan" palsu = UDP telemetri kontrak FALCON dikirim lokal.
# Bagian penting: label HANYA pada sumber buatan, nilai gateware tak pernah ditimpa, trafik live tak dikarang.
set -u
cd "$(dirname "$0")/../falcon/backend"
PY="${FALCON_PY:-python3}"
T=$(mktemp -d); export FALCON_USERS_FILE="$T/users.json"
$PY auth.py add op1 operator >/dev/null
cat > "$T/send.py" <<'EOF'
# kirim telemetri kontrak FALCON ke backend: <port> <mode> ; mode: zero | real
import socket, sys, time, os
sys.path.insert(0, os.path.join(os.environ["FALCON_ROOT"], "falcon"))
from shared import contract as C
port, mode = int(sys.argv[1]), sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
a = ("127.0.0.1", port)
imsi = "510119999999999" if mode == "real" else ""
for i in range(3):
    for t in (0x1000, 0x1001, 0x1002, 0x1003):
        s.sendto(C.pack_teid(t, imsi, 5, 1, 100 + i, 0), a)
    s.sendto(C.pack_global(int(time.time()), 7 if mode == "real" else 0, 120, 0, 9 if mode == "real" else 0, 1000 * (i + 1), 0), a)
    time.sleep(0.4)
EOF
export FALCON_ROOT="$(cd ../.. && pwd)"
B=http://127.0.0.1; PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1 (dapat '$2', mau '$3')"; FAIL=$((FAIL+1)); fi; }
jq1(){ $PY -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
PIDS=""
trap 'kill $PIDS 2>/dev/null; rm -rf "$T"' EXIT

run(){ # $1=port http  $2=port udp  $3=MODE  $4=DEMO_TRAFFIC(spec)  $5=send-mode  -> nyalakan, kirim, tunggu
  FALCON_HTTP_PORT=$1 FALCON_UDP_PORT=$2 FALCON_MODE=$3 FALCON_DEMO_TRAFFIC="$4" FALCON_DEMO_TARGET=127.0.0.1:59999 \
    $PY server.py > "$T/be$1.log" 2>&1 & PIDS="$PIDS $!"
  sleep 2; $PY "$T/send.py" $2 $5; sleep 0.5
}

# ---- A. sumber buatan (demo sim5g), gateware kirim 0 -> label SIM + KPI turunan
run 8101 50101 live "sim5g:30:90:100:campuran:8" zero
G=$(curl -s $B:8101/api/stats/global); TE=$(curl -s $B:8101/api/stats/teid)
chk "A active_teid turunan = jumlah TEID hidup (4)"      "$(echo "$G" | jq1 "d['active_teid']")" 4
chk "A active_teid ditandai turunan"                     "$(echo "$G" | jq1 "d.get('active_teid_derived')")" True
chk "A total_imsi = 4 (label sim)"                       "$(echo "$G" | jq1 "d['total_imsi']")" 4
chk "A total_imsi ditandai simulasi"                     "$(echo "$G" | jq1 "d.get('imsi_synthetic')")" True
chk "A tiap TEID ber-IMSI 15 karakter (3 digit + 12 bintang)" "$(echo "$TE" | jq1 "all(len(x['imsi'])==15 and x['imsi'][:3].isdigit() and set(x['imsi'][3:])=={'*'} for x in d)")" True
chk "A IMSI simulasi berawalan 001 (PLMN uji)"           "$(echo "$TE" | jq1 "all(x['imsi'].startswith('001') for x in d)")" True
chk "A tiap TEID ditandai imsi_synthetic"                "$(echo "$TE" | jq1 "all(x['imsi_synthetic'] for x in d)")" True
chk "A total_imsi tetap menghitung unik walau tersamar"  "$(echo "$G" | jq1 "d['total_imsi']")" 4
SNAP=$(curl -s $B:8101/api/snapshot)
chk "A snapshot (jalur WS/REST) memuat flag yang sama"   "$(echo "$SNAP" | jq1 "d['global'].get('imsi_synthetic') is True and d['global'].get('active_teid_derived') is True")" True
chk "A /api/measure menandai imsi 'simulasi'"            "$(curl -s -b /dev/null $B:8101/api/measure | jq1 "[i['status'] for i in d['items'] if i['k']=='imsi'][0]")" simulasi

# ---- B. IMSI deterministik antar-restart
D1=$($PY -c "import importlib.util as u;s=u.spec_from_file_location('m','server.py');m=u.module_from_spec(s);s.loader.exec_module(m);print(m.synth_imsi('0x00001000'))")
D2=$($PY -c "import importlib.util as u;s=u.spec_from_file_location('m','server.py');m=u.module_from_spec(s);s.loader.exec_module(m);print(m.synth_imsi('0x00001000'))")
chk "B IMSI simulasi deterministik (proses berbeda, sama)"   "$([ "$D1" = "$D2" ] && echo sama || echo beda)" sama
chk "B IMSI simulasi 15 digit berprefiks 00101"           "$([ ${#D1} = 15 ] && [ "${D1:0:5}" = 00101 ] && echo ok || echo salah)" ok

# ---- C. TRAFIK LIVE (tanpa sumber buatan): gateware kirim 0 -> TIDAK dikarang
run 8103 50103 live "" zero
G=$(curl -s $B:8103/api/stats/global); TE=$(curl -s $B:8103/api/stats/teid)
chk "C live: total_imsi tetap 0 (tak dikarang)"          "$(echo "$G" | jq1 "d['total_imsi']")" 0
chk "C live: tak ada flag imsi_synthetic"                "$(echo "$G" | jq1 "d.get('imsi_synthetic')")" None
chk "C live: IMSI per TEID kosong"                       "$(echo "$TE" | jq1 "all(not x['imsi'] for x in d)")" True
chk "C live: tak ada tag synthetic di TEID"              "$(echo "$TE" | jq1 "any(x.get('imsi_synthetic') for x in d)")" False
chk "C live: active_teid tetap dihitung (4, nyata)"      "$(echo "$G" | jq1 "d['active_teid']")" 4

# ---- D. NILAI GATEWARE MENANG: gateware kirim IMSI & angka nyata -> tidak ditimpa
run 8104 50104 live "sim5g:30:90:100:campuran:8" real
G=$(curl -s $B:8104/api/stats/global); TE=$(curl -s $B:8104/api/stats/teid)
chk "D gateware: total_imsi=7 tidak ditimpa"             "$(echo "$G" | jq1 "d['total_imsi']")" 7
chk "D gateware: active_teid=9 tidak ditimpa"            "$(echo "$G" | jq1 "d['active_teid']")" 9
chk "D gateware: IMSI asli dipertahankan (tersamar 510)"  "$(echo "$TE" | jq1 "all(x['imsi']=='510'+'*'*12 for x in d)")" True
chk "D gateware: tidak ditandai simulasi"                "$(echo "$TE" | jq1 "any(x.get('imsi_synthetic') for x in d)")" False
chk "D gateware: tanpa flag turunan"                     "$(echo "$G" | jq1 "(d.get('active_teid_derived'), d.get('imsi_synthetic'))")" "(None, None)"

# ---- E. MODE=sim (simulator internal) dianggap sumber buatan
run 8105 50105 sim "" zero
chk "E mode sim: IMSI berlabel"                          "$(curl -s $B:8105/api/stats/teid | jq1 "all(x.get('imsi_synthetic') for x in d)")" True

# ---- F. TEID mati keluar dari hitungan (TTL)
FALCON_TEID_TTL=1 FALCON_HTTP_PORT=8106 FALCON_UDP_PORT=50106 FALCON_MODE=live FALCON_DEMO_TRAFFIC="" FALCON_DEMO_TARGET=127.0.0.1:59999 \
  $PY server.py > "$T/be8106.log" 2>&1 & PIDS="$PIDS $!"; sleep 2
$PY "$T/send.py" 50106 zero; sleep 3
$PY - <<'EOF'
import socket, sys, os, time
sys.path.insert(0, os.path.join(os.environ["FALCON_ROOT"], "falcon"))
from shared import contract as C
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(C.pack_global(int(time.time()), 0, 0, 0, 0, 5000, 0), ("127.0.0.1", 50106))
EOF
sleep 0.5
chk "F TEID kedaluwarsa (TTL 1 dtk) -> active_teid 0"    "$(curl -s $B:8106/api/stats/global | jq1 "d['active_teid']")" 0

echo "---- $PASS lulus, $FAIL gagal"; [ "$FAIL" = 0 ]
