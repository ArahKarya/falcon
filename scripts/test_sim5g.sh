#!/usr/bin/env bash
# Uji sisi server sumber 'sim-5g': auth, validasi, paket di kabel (pendengar UDP palsu), anomali, stop. Tanpa board.
set -u
cd "$(dirname "$0")/../falcon/backend"
PY="${FALCON_PY:-python3}"
T=$(mktemp -d); export FALCON_USERS_FILE="$T/users.json"
OPW=$($PY auth.py add op1 operator | sed -n 's/.*: //p' | tail -1)
VPW=$($PY auth.py add vw1 viewer   | sed -n 's/.*: //p' | tail -1)

# "board" palsu: tangkap datagram di 127.0.0.1:59998 selama 4 detik, simpan ringkasan JSON
cat > "$T/sink.py" <<'EOF'
import socket, struct, json, sys, time, collections
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 59998)); s.settimeout(0.3)
end = time.time() + float(sys.argv[1]); n = 0; bad = 0; teids = collections.Counter(); qfis = collections.Counter(); size = 0
while time.time() < end:
    try: d, _ = s.recvfrom(4096)
    except socket.timeout: continue
    n += 1; size += len(d)
    ok = len(d) >= 16 and d[0] == 0x34 and d[1] == 0xFF and d[11] == 0x85 and struct.unpack(">H", d[2:4])[0] == len(d) - 8
    bad += (not ok); teids[struct.unpack(">I", d[4:8])[0]] += 1; qfis[d[14] & 0x3F] += 1
json.dump({"n": n, "bad": bad, "teids": len(teids), "qfis": sorted(qfis), "bytes": size, "top": teids.most_common(1)[0] if teids else None}, open(sys.argv[2], "w"))
EOF

FALCON_HTTP_PORT=8094 FALCON_UDP_PORT=50094 FALCON_MODE=sim FALCON_DEMO_TARGET=127.0.0.1:59998 \
  $PY server.py > "$T/be.log" 2>&1 & BE=$!
trap 'kill $BE 2>/dev/null; rm -rf "$T"' EXIT
sleep 2
B=http://127.0.0.1:8094; PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1 (dapat '$2', mau '$3')"; FAIL=$((FAIL+1)); fi; }
code(){ curl -s -o /dev/null -w "%{http_code}" "$@"; }
jq1(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
H='content-type: application/json'
START='{"source":"sim-5g","pps":400,"on_s":60,"off_s":0,"sim5g":{"preset":"campuran","ues":32,"burst":1.0}}'

curl -s -c "$T/op.jar" -X POST $B/api/login -d "{\"username\":\"op1\",\"password\":\"$OPW\"}" -o /dev/null
curl -s -c "$T/vw.jar" -X POST $B/api/login -d "{\"username\":\"vw1\",\"password\":\"$VPW\"}" -o /dev/null

chk "start tanpa login -> 401"                 "$(code -X POST $B/api/traffic/start -H "$H" -d "$START")" 401
chk "inject tanpa login -> 401"                "$(code -X POST $B/api/sim5g/inject -H "$H" -d '{}')" 401
chk "status sim5g tanpa login -> 401"          "$(code $B/api/sim5g)" 401
chk "start oleh viewer -> 403"                 "$(code -b $T/vw.jar -X POST $B/api/traffic/start -H "$H" -d "$START")" 403
chk "inject saat belum berjalan -> 409"        "$(code -b $T/op.jar -X POST $B/api/sim5g/inject -H "$H" -d '{"factor":3,"seconds":5}')" 409
chk "daftar sumber memuat sim-5g"              "$(curl -s -b $T/op.jar $B/api/setup/traffic | jq1 "'sim-5g' in [s['id'] for s in d['sources']]")" True
chk "setup memuat 8 aplikasi + 4 preset"       "$(curl -s -b $T/op.jar $B/api/setup/traffic | jq1 "(len(d['sim5g']['apps']),len(d['sim5g']['presets']))")" "(8, 4)"

chk "preset tak dikenal -> 400"                "$(code -b $T/op.jar -X POST $B/api/traffic/start -H "$H" -d '{"source":"sim-5g","pps":100,"on_s":5,"off_s":0,"sim5g":{"preset":"ngawur"}}')" 400
chk "mix aplikasi tak dikenal -> 400"          "$(code -b $T/op.jar -X POST $B/api/traffic/start -H "$H" -d '{"source":"sim-5g","pps":100,"on_s":5,"off_s":0,"sim5g":{"mix":{"xx":1}}}')" 400
chk "ues di luar batas -> 400"                 "$(code -b $T/op.jar -X POST $B/api/traffic/start -H "$H" -d '{"source":"sim-5g","pps":100,"on_s":5,"off_s":0,"sim5g":{"ues":99999}}')" 400
chk "burst bukan angka -> 400"                 "$(code -b $T/op.jar -X POST $B/api/traffic/start -H "$H" -d '{"source":"sim-5g","pps":100,"on_s":5,"off_s":0,"sim5g":{"burst":"x"}}')" 400
chk "gagal validasi tidak menyalakan trafik"   "$(curl -s $B/api/demo | jq1 "d['enabled']")" False

# --- jalankan & tangkap di kabel ---
$PY "$T/sink.py" 5 "$T/cap1.json" & SK=$!
sleep 0.5
chk "start sim-5g valid -> 200"                "$(code -b $T/op.jar -X POST $B/api/traffic/start -H "$H" -d "$START")" 200
wait $SK
chk "sumber tercatat sim-5g"                   "$(curl -s $B/api/demo | jq1 "d['source']")" sim-5g
chk "paket tiba di kabel (>=1200 dari ~400pps x ~4.5dtk)" "$(python3 -c "import json;print('ok' if json.load(open('$T/cap1.json'))['n']>=1200 else json.load(open('$T/cap1.json')))")" ok
chk "SEMUA paket valid (0x34/FF/0x85/length)"  "$(python3 -c "import json;print(json.load(open('$T/cap1.json'))['bad'])")" 0
chk "banyak TEID berbeda di kabel (>=10)"      "$(python3 -c "import json;print('ok' if json.load(open('$T/cap1.json'))['teids']>=10 else json.load(open('$T/cap1.json')))")" ok
chk "beragam QFI (>=3)"                        "$(python3 -c "import json;print('ok' if len(json.load(open('$T/cap1.json'))['qfis'])>=3 else json.load(open('$T/cap1.json')))")" ok
chk "status memuat peta TEID->aplikasi"        "$(curl -s -b $T/op.jar $B/api/sim5g | jq1 "len(d['teids'])>=10 and all('app' in v for v in d['teids'].values())")" True
chk "pencacah backend ~ terkirim"              "$(curl -s -b $T/op.jar $B/api/sim5g | jq1 "d['sent_pkts'] >= 1200")" True

# --- anomali: lonjakan nyata di kabel ---
APP=$(curl -s -b $T/op.jar $B/api/sim5g | jq1 "max(d['per_app'],key=lambda a:d['per_app'][a]['pkts'])")
chk "inject factor di luar batas -> 400"       "$(code -b $T/op.jar -X POST $B/api/sim5g/inject -H "$H" -d '{"factor":99,"seconds":5}')" 400
chk "inject app tak dikenal -> 400"            "$(code -b $T/op.jar -X POST $B/api/sim5g/inject -H "$H" -d '{"factor":3,"seconds":5,"app":"ngawur"}')" 400
chk "inject viewer -> 403"                     "$(code -b $T/vw.jar -X POST $B/api/sim5g/inject -H "$H" -d '{"factor":3,"seconds":5}')" 403
$PY "$T/sink.py" 3 "$T/cap_base.json" & SK=$!; wait $SK
chk "inject valid -> 200"                      "$(code -b $T/op.jar -X POST $B/api/sim5g/inject -H "$H" -d '{"factor":5,"seconds":30}')" 200
$PY "$T/sink.py" 3 "$T/cap_spike.json" & SK=$!; wait $SK
chk "laju di kabel naik >2x saat anomali"      "$(python3 -c "
import json;b=json.load(open('$T/cap_base.json'))['n'];s=json.load(open('$T/cap_spike.json'))['n'];print('ok' if s>b*2 else (b,s))")" ok
chk "anomali tercatat di status"               "$(curl -s -b $T/op.jar $B/api/sim5g | jq1 "len(d['anomalies'])")" 1

# --- stop ---
chk "stop -> 200"                              "$(code -b $T/op.jar -X POST $B/api/traffic/stop)" 200
chk "setelah stop: demo mati"                  "$(curl -s $B/api/demo | jq1 "d['enabled']")" False
chk "setelah stop: generator dibuang"          "$(curl -s -b $T/op.jar $B/api/sim5g | jq1 "d['active']")" False
$PY "$T/sink.py" 2 "$T/cap_stop.json" & SK=$!; wait $SK
chk "setelah stop: tak ada paket lagi"         "$(python3 -c "import json;print(json.load(open('$T/cap_stop.json'))['n'])")" 0

# --- regresi sumber lama tetap jalan ---
chk "sumber synthetic masih jalan -> 200"      "$(code -b $T/op.jar -X POST $B/api/traffic/start -H "$H" -d '{"source":"synthetic","pps":50,"on_s":5,"off_s":0}')" 200
chk "synthetic: sumber tercatat"               "$(curl -s $B/api/demo | jq1 "d['source']")" synthetic
curl -s -b $T/op.jar -X POST $B/api/traffic/stop -o /dev/null
chk "ganti sim-5g -> sim-5g (restart bersih)"  "$(code -b $T/op.jar -X POST $B/api/traffic/start -H "$H" -d "$START")" 200
chk "start kedua tidak membocorkan task"       "$(code -b $T/op.jar -X POST $B/api/traffic/start -H "$H" -d "$START")" 200
sleep 1.5
chk "satu generator aktif, sumber sim-5g"      "$(curl -s -b $T/op.jar $B/api/sim5g | jq1 "d['active'] and d['sent_pkts']>0")" True
echo "---- $PASS lulus, $FAIL gagal"; [ "$FAIL" = 0 ]
