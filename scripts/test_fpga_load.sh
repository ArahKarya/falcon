#!/usr/bin/env bash
# Uji sisi server tombol "Muat gateware": fpgactl PALSU, tidak menyentuh papan/JTAG/lab.
set -u
cd "$(dirname "$0")/../falcon/backend"
PY="${FALCON_PY:-python3}"
T=$(mktemp -d); export FALCON_USERS_FILE="$T/users.json"
OPW=$($PY auth.py add op1 operator | sed -n 's/.*: //p' | tail -1)
VPW=$($PY auth.py add vw1 viewer   | sed -n 's/.*: //p' | tail -1)

cat > "$T/fpgactl.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status) echo '{"jtag_cable": true, "eth_link": false, "host_ip": true, "bitstream_sha": "8bf0fc60", "board_ip": "192.168.0.20"}' ;;
  load)   sleep 1; [ -f "$FAKE_FAIL" ] && { echo "[fpgactl] iMPACT gagal (rc=1):" >&2; exit 5; }; echo "[fpgactl] telemetri masuk" >&2; exit 0 ;;
esac
EOF
chmod +x "$T/fpgactl.sh"

FALCON_FPGACTL="$T/fpgactl.sh" FAKE_FAIL="$T/fail" FALCON_HTTP_PORT=8093 FALCON_UDP_PORT=50093 FALCON_MODE=sim \
  FALCON_DEMO_TARGET=127.0.0.1:59999 $PY server.py > "$T/be.log" 2>&1 &
BE=$!
trap 'kill $BE 2>/dev/null; rm -rf "$T"' EXIT
sleep 2
B=http://127.0.0.1:8093; PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1 (dapat '$2', mau '$3')"; FAIL=$((FAIL+1)); fi; }
code(){ curl -s -o /dev/null -w "%{http_code}" "$@"; }
jq1(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
waitphase(){ for i in $(seq 1 30); do p=$(curl -s -b $T/op.jar $B/api/setup/fpga | jq1 "d['loader']['job']['phase']"); case "$p" in done|error) echo $p; return;; esac; sleep 0.4; done; echo $p; }

curl -s -c "$T/op.jar" -X POST $B/api/login -d "{\"username\":\"op1\",\"password\":\"$OPW\"}" -o /dev/null
curl -s -c "$T/vw.jar" -X POST $B/api/login -d "{\"username\":\"vw1\",\"password\":\"$VPW\"}" -o /dev/null

chk "load tanpa login -> 401"                 "$(code -X POST $B/api/fpga/load)" 401
chk "load viewer -> 403"                      "$(code -b $T/vw.jar -X POST $B/api/fpga/load)" 403
chk "loader terdeteksi terpasang"             "$(curl -s -b $T/op.jar $B/api/setup/fpga | jq1 "d['loader']['installed']")" True
chk "status memuat hash bitstream"            "$(curl -s -b $T/op.jar $B/api/setup/fpga | jq1 "d['loader']['bitstream_sha']")" 8bf0fc60
chk "status melaporkan kabel ethernet putus"  "$(curl -s -b $T/op.jar $B/api/setup/fpga | jq1 "d['loader']['eth_link']")" False
chk "load operator saat papan putus -> 200"   "$(code -b $T/op.jar -X POST $B/api/fpga/load)" 200
chk "load ganda saat berjalan -> 409"         "$(code -b $T/op.jar -X POST $B/api/fpga/load)" 409
chk "pemuatan selesai (done)"                 "$(waitphase)" done

touch "$T/fail"
chk "load gagal -> 200 (job dimulai)"         "$(code -b $T/op.jar -X POST $B/api/fpga/load)" 200
chk "kegagalan dilaporkan (error)"            "$(waitphase)" error
chk "pesan galat memuat alasan operator"      "$(curl -s -b $T/op.jar $B/api/setup/fpga | jq1 "'iMPACT' in d['loader']['job']['msg']")" True
rm -f "$T/fail"

# papan sudah terhubung -> tolak (jangan reprogram papan yang sehat)
python3 - <<EOF
import socket,sys
sys.path.insert(0,"$PWD/..")
from shared import contract as C
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
for _ in range(5): s.sendto(C.pack_global(1,0,10,0,0,100,0),("127.0.0.1",50093))
EOF
sleep 0.5
chk "papan terhubung -> load ditolak 409"     "$(code -b $T/op.jar -X POST $B/api/fpga/load)" 409
chk "tombol tidak menerima parameter berkas"  "$(code -b $T/op.jar -X POST $B/api/fpga/load -d '{"file":"/etc/passwd"}')" 409
echo "---- $PASS lulus, $FAIL gagal"; [ "$FAIL" = 0 ]
