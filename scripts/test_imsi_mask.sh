#!/usr/bin/env bash
# Uji penyamaran IMSI: hanya 3 digit depan keluar dari backend lewat SEMUA jalur (REST, snapshot, WebSocket, rawlog),
# untuk IMSI simulasi MAUPUN IMSI asli dari gateware. Hitungan unik tetap benar.
set -u
cd "$(dirname "$0")/../falcon/backend"
PY="${FALCON_PY:-python3}"
T=$(mktemp -d); export FALCON_USERS_FILE="$T/users.json"
export FALCON_ROOT="$(cd ../.. && pwd)"
cat > "$T/send.py" <<'EOF'
import socket, sys, time, os
sys.path.insert(0, os.path.join(os.environ["FALCON_ROOT"], "falcon"))
from shared import contract as C
port, imsi = int(sys.argv[1]), sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); a = ("127.0.0.1", port)
for i in range(2):
    for t in (0x1000, 0x1001, 0x1002):
        s.sendto(C.pack_teid(t, imsi, 5, 1, 100 + i, 0), a)
    s.sendto(C.pack_global(int(time.time()), 0, 100, 0, 0, 1000, 0), a)
    time.sleep(0.3)
EOF
cat > "$T/ws.py" <<'EOF'
import asyncio, json, sys, aiohttp
async def main(port):
    seen = []
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect(f"http://127.0.0.1:{port}/ws") as ws:
            end = asyncio.get_event_loop().time() + 4
            while asyncio.get_event_loop().time() < end:
                try:
                    m = await ws.receive(timeout=1)
                except asyncio.TimeoutError:
                    continue
                if m.type == aiohttp.WSMsgType.TEXT:
                    seen.append(m.data)
    print(json.dumps(seen))
asyncio.run(main(int(sys.argv[1])))
EOF
PASS=0; FAIL=0; PIDS=""
trap 'kill $PIDS 2>/dev/null; rm -rf "$T"' EXIT
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1 (dapat '$2', mau '$3')"; FAIL=$((FAIL+1)); fi; }
jq1(){ $PY -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
B=http://127.0.0.1

start(){ FALCON_HTTP_PORT=$1 FALCON_UDP_PORT=$2 FALCON_MODE=live FALCON_DEMO_TRAFFIC="$3" FALCON_DEMO_TARGET=127.0.0.1:59999 \
  $PY server.py > "$T/be$1.log" 2>&1 & PIDS="$PIDS $!"; sleep 2; }

# ---- A. IMSI ASLI dari gateware (510119999999999): 3 digit depan saja keluar
REAL=510119999999999
start 8201 50201 ""
( $PY "$T/ws.py" 8201 > "$T/ws.out" & W=$!; sleep 1; $PY "$T/send.py" 50201 $REAL; wait $W )
TE=$(curl -s $B:8201/api/stats/teid); SN=$(curl -s $B:8201/api/snapshot); RW=$(curl -s $B:8201/api/rawlog)
chk "A REST: IMSI = 510 + 12 bintang"                 "$(echo "$TE" | jq1 "all(x['imsi']=='510'+'*'*12 for x in d)")" True
chk "A REST: panjang tetap 15"                         "$(echo "$TE" | jq1 "all(len(x['imsi'])==15 for x in d)")" True
chk "A REST: IMSI penuh tidak ada di respons"          "$(echo "$TE" | grep -c $REAL)" 0
chk "A REST: 4 digit depan tak bocor (5101)"           "$(echo "$TE" | grep -c 5101)" 0
chk "A snapshot: IMSI tersamar"                        "$(echo "$SN" | jq1 "all(x['imsi']=='510'+'*'*12 for x in d['teid'])")" True
chk "A snapshot: IMSI penuh tidak ada"                 "$(echo "$SN" | grep -c $REAL)" 0
chk "A rawlog: IMSI penuh tidak ada"                   "$(echo "$RW" | grep -c $REAL)" 0
chk "A rawlog: hex TEID dipotong, tanpa byte IMSI"     "$(echo "$RW" | jq1 "all(len(x['hex'].rstrip('…'))==16 for x in d if x['type']=='TEID')")" True
HEXIMSI=$($PY -c "print('$REAL'.encode().hex()[:16])")
chk "A rawlog: ASCII IMSI (hex) tidak ada"             "$(echo "$RW" | grep -c $HEXIMSI)" 0
chk "A WebSocket: ada pesan teid"                      "$($PY -c "import json;print(any(json.loads(m).get('type')=='teid' for m in json.load(open('$T/ws.out'))))")" True
chk "A WebSocket: IMSI penuh tidak ada"                "$(grep -c $REAL "$T/ws.out")" 0
chk "A WebSocket: IMSI tersamar"                       "$($PY -c "import json;r=[json.loads(m)['data']['imsi'] for m in json.load(open('$T/ws.out')) if json.loads(m).get('type')=='teid'];print(bool(r) and all(x=='510'+'*'*12 for x in r))")" True
chk "A bendera imsi_synthetic=False (asli)"            "$(echo "$TE" | jq1 "any(x.get('imsi_synthetic') for x in d)")" False

# ---- B. IMSI SIMULASI (demo): disamarkan, hitungan unik tetap benar
start 8202 50202 "sim5g:30:90:100:campuran:8"
$PY "$T/send.py" 50202 ""; sleep 0.5
TE=$(curl -s $B:8202/api/stats/teid); G=$(curl -s $B:8202/api/stats/global)
chk "B simulasi: IMSI 001 + 12 bintang"                "$(echo "$TE" | jq1 "all(x['imsi']=='001'+'*'*12 for x in d)")" True
chk "B simulasi: prefiks PLMN 00101 tak bocor"         "$(echo "$TE" | grep -c 00101)" 0
chk "B total_imsi tetap menghitung unik (3 TEID)"      "$(echo "$G" | jq1 "d['total_imsi']")" 3
chk "B tetap ditandai simulasi"                        "$(echo "$TE" | jq1 "all(x['imsi_synthetic'] for x in d)")" True

# ---- C. Ekspor CSV di dashboard memakai data tersamar (tak ada sumber penuh di browser)
chk "C data klien hanya dari API (tersamar), tak ada IMSI penuh di index.html" "$(grep -c 'synth_imsi\|SYNTH_PLMN' ../dashboard/index.html)" 0

# ---- D. Unit: mask_imsi
$PY - <<'EOF' > "$T/unit.out"
import sys; sys.argv=["x"]
import importlib.util, os
spec = importlib.util.spec_from_file_location("srv", "server.py"); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r = []
r.append(m.mask_imsi("510119999999999") == "510" + "*"*12)
r.append(m.mask_imsi("") == "")
r.append(m.mask_imsi(None) == "")
r.append(m.mask_imsi("12") == "12")                 # lebih pendek dari 3: tak diperpanjang
r.append(len(m.mask_imsi("999700000000001")) == 15)
print(all(r))
EOF
chk "D unit mask_imsi (kosong, None, pendek, panjang)"  "$(tail -1 "$T/unit.out")" True

echo "---- $PASS lulus, $FAIL gagal"; [ "$FAIL" = 0 ]
