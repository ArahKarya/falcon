#!/usr/bin/env bash
# Uji sisi server: auth, gate, validasi, kontrol trafik. Akun & port sementara, tidak menyentuh board.
set -u
cd "$(dirname "$0")/../falcon/backend"
PY="${FALCON_PY:-python3}"
T=$(mktemp -d); export FALCON_USERS_FILE="$T/users.json"
OPW=$($PY auth.py add op1 operator | sed -n 's/.*: //p' | tail -1)
VPW=$($PY auth.py add vw1 viewer   | sed -n 's/.*: //p' | tail -1)
FALCON_HTTP_PORT=8091 FALCON_UDP_PORT=50091 FALCON_MODE=sim FALCON_DEMO_TARGET=127.0.0.1:59999 \
  $PY server.py > "$T/be.log" 2>&1 & BE=$!
trap 'kill $BE 2>/dev/null; rm -rf "$T"' EXIT
sleep 2
B=http://127.0.0.1:8091; PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1 (dapat '$2', mau '$3')"; FAIL=$((FAIL+1)); fi; }
code(){ curl -s -o /dev/null -w "%{http_code}" "$@"; }

chk "dashboard terbuka tanpa login"            "$(code $B/)" 200
chk "halaman setup tanpa login -> redirect"    "$(code $B/setup/traffic)" 302
chk "API setup tanpa login -> 401"             "$(code $B/api/setup/traffic)" 401
chk "start trafik tanpa login -> 401"          "$(code -X POST $B/api/traffic/start -H 'content-type: application/json' -d '{}')" 401
chk "generator start tanpa login -> 401"       "$(code -X POST $B/api/generator/start)" 401
chk "login sandi salah -> 401"                 "$(code -X POST $B/api/login -d '{"username":"op1","password":"salah"}')" 401
chk "login akun tak ada -> 401"                "$(code -X POST $B/api/login -d '{"username":"nobody","password":"x"}')" 401

curl -s -c "$T/op.jar" -X POST $B/api/login -d "{\"username\":\"op1\",\"password\":\"$OPW\"}" -o "$T/l.json"
chk "login operator benar"                      "$(python3 -c "import json;print(json.load(open('$T/l.json'))['role'])")" operator
chk "cookie HttpOnly + SameSite=Strict"         "$(grep -c HttpOnly "$T/op.jar")" 1
chk "operator buka API setup -> 200"            "$(code -b "$T/op.jar" $B/api/setup/traffic)" 200
chk "operator buka halaman setup -> 404/200 (file belum/ada)" "$([ "$(code -b "$T/op.jar" $B/setup/traffic)" != 302 ] && echo ok)" ok
chk "start: pps di luar batas -> 400"           "$(code -b "$T/op.jar" -X POST $B/api/traffic/start -d '{"pps":999999,"on_s":5,"off_s":5}')" 400
chk "start: bukan angka -> 400"                 "$(code -b "$T/op.jar" -X POST $B/api/traffic/start -d '{"pps":"x","on_s":5,"off_s":5}')" 400
chk "start valid -> 200"                        "$(code -b "$T/op.jar" -X POST $B/api/traffic/start -d '{"pps":50,"on_s":5,"off_s":0}')" 200
sleep 2
SENT=$(curl -s $B/api/demo | python3 -c "import sys,json;d=json.load(sys.stdin);print('ok' if d['enabled'] and d['sent']>20 else d)")
chk "trafik benar-benar jalan (sent>20)"        "$SENT" ok
chk "stop -> 200"                               "$(code -b "$T/op.jar" -X POST $B/api/traffic/stop)" 200
chk "setelah stop enabled=false"                "$(curl -s $B/api/demo | python3 -c "import sys,json;print(json.load(sys.stdin)['enabled'])")" False

curl -s -c "$T/vw.jar" -X POST $B/api/login -d "{\"username\":\"vw1\",\"password\":\"$VPW\"}" -o /dev/null
chk "viewer boleh BACA setup"                   "$(code -b "$T/vw.jar" $B/api/setup/fpga)" 200
chk "viewer DITOLAK start trafik -> 403"        "$(code -b "$T/vw.jar" -X POST $B/api/traffic/start -d '{"pps":10,"on_s":5,"off_s":5}')" 403
chk "viewer DITOLAK generator -> 403"           "$(code -b "$T/vw.jar" -X POST $B/api/generator/start)" 403

chk "logout -> 200"                             "$(code -b "$T/op.jar" -X POST $B/api/logout)" 200
chk "sesi lama setelah logout -> 401"           "$(code -b "$T/op.jar" $B/api/setup/traffic)" 401

for i in 1 2 3 4 5; do code -X POST $B/api/login -d '{"username":"op1","password":"x"}' >/dev/null; done
chk "5 gagal -> terkunci 429"                   "$(code -X POST $B/api/login -d "{\"username\":\"op1\",\"password\":\"$OPW\"}")" 429
chk "sandi tak muncul di log server"            "$(grep -c "$OPW" "$T/be.log")" 0
echo "---- $PASS lulus, $FAIL gagal"; [ "$FAIL" = 0 ]
