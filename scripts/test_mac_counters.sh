#!/usr/bin/env bash
# Uji counter drop MAC end-to-end di backend: kontrak (byte-exact), gateware BARU vs LAMA, laju drop, tampilan.
set -u
cd "$(dirname "$0")/../falcon/backend"
PY="${FALCON_PY:-python3}"
T=$(mktemp -d); export FALCON_USERS_FILE="$T/users.json"; export FALCON_ROOT="$(cd ../.. && pwd)"
PASS=0; FAIL=0; PIDS=""
trap 'kill $PIDS 2>/dev/null; rm -rf "$T"' EXIT
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1 (dapat '$2', mau '$3')"; FAIL=$((FAIL+1)); fi; }
jq1(){ $PY -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

# ---- A. kontrak: roundtrip + kompatibilitas mundur
cat > "$T/c.py" <<'EOF'
import sys, os
sys.path.insert(0, os.path.join(os.environ["FALCON_ROOT"], "falcon"))
from shared import contract as C
r = []
# baru: ekstensi terisi
b = C.pack_global(100, 1, 2, 3, 4, 5, 9, 11, 4, 7, 123456, 0)
d = C.decode(b)["data"]
r.append(len(b) == 68)
r.append(d["mac_counters"] is True and d["mac_drop"] == 11 and d["mac_overflow"] == 4 and d["mac_bad_frame"] == 7 and d["mac_frames_ok"] == 123456)
r.append(d["drop_count"] == 9 and d["total_bytes"] == 5)             # field lama TIDAK bergeser
# lama: padding nol -> tanpa kunci mac_*
o = C.pack_global(100, 1, 2, 3, 4, 5, 9)
d2 = C.decode(o)["data"]
r.append("mac_counters" not in d2 and "mac_drop" not in d2 and d2["drop_count"] == 9)
# payload 32B lama (tanpa padding sama sekali) tetap terbaca
hdr = C.make_header(C.TYPE_GLOBAL, b"\x00" * 32)
r.append(C.decode(hdr)["data"]["drop_count"] == 0)
print(all(r))
EOF
chk "A kontrak: roundtrip, field lama tetap, bitstream lama kompatibel" "$($PY "$T/c.py")" True

# ---- B. backend: gateware BARU mengirim counter MAC
cat > "$T/send.py" <<'EOF'
import socket, sys, time, os
sys.path.insert(0, os.path.join(os.environ["FALCON_ROOT"], "falcon"))
from shared import contract as C
port, mode = int(sys.argv[1]), sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); a = ("127.0.0.1", port)
base = int(time.time())
for i in range(4):
    if mode == "new":     # 1000 frame sah per detik; drop MAC naik 20/detik -> laju = 20/(1000+20) = 1,96%
        s.sendto(C.pack_global(base + i, 0, 100, 0, 0, 1000 * (i + 1), 20 * (i + 1), 20 * (i + 1), 15 * (i + 1), 5 * (i + 1), 1000 * (i + 1), 0), a)
    else:                 # gateware lama: counter MAC tak ada
        s.sendto(C.pack_global(base + i, 0, 100, 0, 0, 1000 * (i + 1), 0), a)
    time.sleep(0.25)
EOF
start(){ FALCON_HTTP_PORT=$1 FALCON_UDP_PORT=$2 FALCON_MODE=live FALCON_DEMO_TRAFFIC="" $PY server.py > "$T/be$1.log" 2>&1 & PIDS="$PIDS $!"; sleep 2; }

start 8301 50301; $PY "$T/send.py" 50301 new; sleep 0.5
G=$(curl -s http://127.0.0.1:8301/api/stats/global)
chk "B baru: mac_counters tampil"            "$(echo "$G" | jq1 "d.get('mac_counters')")" True
chk "B baru: frame sah kumulatif = 4000"     "$(echo "$G" | jq1 "d.get('mac_frames_ok')")" 4000
chk "B baru: overflow = 60, tak valid = 20"  "$(echo "$G" | jq1 "(d.get('mac_overflow'), d.get('mac_bad_frame'))")" "(60, 20)"
chk "B baru: field drop lama = 80 (terisi)"  "$(echo "$G" | jq1 "d['drop_count']")" 80
chk "B baru: laju drop = 1,96% (drop/(sah+drop))" "$(echo "$G" | jq1 "round(d['drop_rate'], 2)")" 1.96
chk "B baru: delta drop 20/dtk"              "$(echo "$G" | jq1 "d['drop_delta']")" 20
chk "B baru: /api/measure drop = 'sebagian'" "$(curl -s http://127.0.0.1:8301/api/measure | jq1 "[i['status'] for i in d['items'] if i['k']=='drop'][0]")" sebagian
chk "B baru: snapshot (jalur WS) memuat counter MAC" "$(curl -s http://127.0.0.1:8301/api/snapshot | jq1 "d['global'].get('mac_counters')")" True

# ---- C. gateware LAMA: tidak ada counter palsu, perilaku lama utuh
start 8302 50302; $PY "$T/send.py" 50302 old; sleep 0.5
G=$(curl -s http://127.0.0.1:8302/api/stats/global)
chk "C lama: tanpa 'mac_counters'"           "$(echo "$G" | jq1 "'mac_counters' in d")" False
chk "C lama: tanpa kunci mac_*"              "$(echo "$G" | jq1 "any(k.startswith('mac_') for k in d)")" False
chk "C lama: drop tetap 0"                   "$(echo "$G" | jq1 "d['drop_count']")" 0
chk "C lama: laju drop 0"                    "$(echo "$G" | jq1 "float(d['drop_rate']) == 0")" True

# ---- D. counter reset (gateware di-load ulang): laju tak negatif / tak melonjak
cat > "$T/rs.py" <<'EOF'
import socket, sys, time, os
sys.path.insert(0, os.path.join(os.environ["FALCON_ROOT"], "falcon"))
from shared import contract as C
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); a = ("127.0.0.1", int(sys.argv[1]))
b = int(time.time()) + 100
s.sendto(C.pack_global(b,     0, 100, 0, 0, 9000, 500, 500, 400, 100, 90000, 0), a); time.sleep(0.25)
s.sendto(C.pack_global(b + 1, 0, 100, 0, 0, 100,    2,   2,   1,   1,   50, 0), a); time.sleep(0.25)   # reset: nilai turun
EOF
$PY "$T/rs.py" 50301; sleep 0.5
G=$(curl -s http://127.0.0.1:8301/api/stats/global)
chk "D reset counter: laju drop tak negatif dan <= 100" "$(echo "$G" | jq1 "0 <= d['drop_rate'] <= 100")" True
chk "D reset counter: delta drop 0 (bukan negatif)"     "$(echo "$G" | jq1 "d['drop_delta']")" 0

echo "---- $PASS lulus, $FAIL gagal"; [ "$FAIL" = 0 ]
