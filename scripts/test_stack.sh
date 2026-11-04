#!/usr/bin/env bash
# Uji sisi server untuk sumber "Stack LTE": alur siapkan->tangkap->replay, validasi, hak akses.
# Memakai stackctl PALSU (tidak menyentuh docker/lab/board) dan pcap sintetis berformat asli.
set -u
cd "$(dirname "$0")/../falcon/backend"
PY="${FALCON_PY:-python3}"
T=$(mktemp -d); export FALCON_USERS_FILE="$T/users.json"
OPW=$($PY auth.py add op1 operator | sed -n 's/.*: //p' | tail -1)
VPW=$($PY auth.py add vw1 viewer   | sed -n 's/.*: //p' | tail -1)
mkdir -p "$T/stack/pcap"

# stackctl palsu: meniru kontrak status/up/capture/down, menulis pcap sungguhan (Ethernet/IPv4/UDP:2152, G-PDU)
cat > "$T/stackctl.sh" <<'EOF'
#!/usr/bin/env bash
D="$FALCON_STACK_DIR"; S="$D/.state"
case "$1" in
  status) st=$(cat "$S" 2>/dev/null || echo stopped)
          python3 - "$st" "$D/pcap/stack-lte.pcap" <<'PY'
import json,os,sys,time
st,p=sys.argv[1:3]; cap=None
if os.path.exists(p): cap={"packets":30,"bytes":os.path.getsize(p),"age_s":int(time.time()-os.stat(p).st_mtime)}
print(json.dumps({"state":st,"containers":[{"name":"falcon_epc","up":st!="stopped"}],"ue_ip":"10.45.0.3" if st=="running" else "","capture":cap}))
PY
  ;;
  up) sleep 1; echo running > "$S" ;;
  capture) python3 - "$D/pcap/stack-lte.pcap" <<'PY'
import struct,sys
def frame(teid,n):
    inner=b"\x45\x00"+struct.pack(">H",20+n)+b"\x00"*4+b"\x40\x11\x00\x00"+bytes([10,45,0,3])+bytes([10,45,0,1])+b"X"*n
    g=struct.pack(">BBHI",0x30,0xFF,len(inner),teid)+inner
    udp=struct.pack(">HHHH",2152,2152,8+len(g),0)+g
    ip=b"\x45\x00"+struct.pack(">H",20+len(udp))+b"\x00\x00\x40\x00\x40\x11\x00\x00"+bytes([192,168,0,131])+bytes([192,168,0,130])
    return b"\x00"*12+b"\x08\x00"+ip+udp
with open(sys.argv[1],"wb") as f:
    f.write(struct.pack("<IHHiIII",0xa1b2c3d4,2,4,0,0,65535,1))
    for i in range(30):
        fr=frame(0x728,50+i)
        f.write(struct.pack("<IIII",i,0,len(fr),len(fr)))+fr if False else (f.write(struct.pack("<IIII",i,0,len(fr),len(fr))),f.write(fr))
PY
  ;;
  down) echo stopped > "$S" ;;
esac
EOF
chmod +x "$T/stackctl.sh"

FALCON_STACK_DIR="$T/stack" FALCON_STACKCTL="$T/stackctl.sh" \
FALCON_HTTP_PORT=8092 FALCON_UDP_PORT=50092 FALCON_MODE=sim FALCON_DEMO_TARGET=127.0.0.1:59999 \
  $PY server.py > "$T/be.log" 2>&1 & BE=$!
trap 'kill $BE 2>/dev/null; rm -rf "$T"' EXIT
sleep 2
B=http://127.0.0.1:8092; PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1 (dapat '$2', mau '$3')"; FAIL=$((FAIL+1)); fi; }
code(){ curl -s -o /dev/null -w "%{http_code}" "$@"; }
jq1(){ python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

curl -s -c "$T/op.jar" -X POST $B/api/login -d "{\"username\":\"op1\",\"password\":\"$OPW\"}" -o /dev/null
curl -s -c "$T/vw.jar" -X POST $B/api/login -d "{\"username\":\"vw1\",\"password\":\"$VPW\"}" -o /dev/null

chk "stack prepare tanpa login -> 401"        "$(code -X POST $B/api/stack/prepare)" 401
chk "stack prepare viewer -> 403"             "$(code -b $T/vw.jar -X POST $B/api/stack/prepare)" 403
chk "stack stop viewer -> 403"                "$(code -b $T/vw.jar -X POST $B/api/stack/stop)" 403
chk "status awal: stack stopped"              "$(curl -s -b $T/op.jar $B/api/setup/traffic | jq1 "d['stack']['state']")" stopped
chk "replay tanpa tangkapan -> 409"           "$(code -b $T/op.jar -X POST $B/api/traffic/start -d '{"source":"stack-lte","pps":50,"on_s":5,"off_s":0}')" 409
chk "sumber tak dikenal -> 400"               "$(code -b $T/op.jar -X POST $B/api/traffic/start -d '{"source":"hack","pps":50,"on_s":5,"off_s":0}')" 400
chk "prepare operator -> 200"                 "$(code -b $T/op.jar -X POST $B/api/stack/prepare -d '{"keep_running":false,"secs":5,"pps":50}')" 200
chk "prepare ganda saat sibuk -> 409"         "$(code -b $T/op.jar -X POST $B/api/stack/prepare -d '{}')" 409
for i in $(seq 1 20); do
  ph=$(curl -s -b $T/op.jar $B/api/setup/traffic | jq1 "d['stack']['job']['phase']"); [ "$ph" = done ] && break; sleep 0.5
done
chk "job selesai (done)"                      "$ph" done
chk "tangkapan terdeteksi di status"          "$(curl -s -b $T/op.jar $B/api/setup/traffic | jq1 "d['stack']['capture'] is not None")" True
chk "stack dimatikan lagi (keep_running=false)" "$(curl -s -b $T/op.jar $B/api/setup/traffic | jq1 "d['stack']['state']")" stopped
chk "replay stack-lte -> 200"                 "$(code -b $T/op.jar -X POST $B/api/traffic/start -d '{"source":"stack-lte","pps":100,"on_s":5,"off_s":0}')" 200
sleep 1.5
chk "demo.source = stack-lte"                 "$(curl -s $B/api/demo | jq1 "d['source']")" stack-lte
chk "pool = 30 paket dari pcap"               "$(curl -s $B/api/demo | jq1 "d['pool']")" 30
chk "paket terkirim > 50"                     "$(curl -s $B/api/demo | jq1 "'ok' if d['sent']>50 else d['sent']")" ok
chk "stop -> 200"                             "$(code -b $T/op.jar -X POST $B/api/traffic/stop)" 200
chk "start sintetis kembali source=synthetic" "$(curl -s -b $T/op.jar -X POST $B/api/traffic/start -d '{"pps":50,"on_s":5,"off_s":0}' | jq1 "d['demo']['source']")" synthetic
echo "---- $PASS lulus, $FAIL gagal"; [ "$FAIL" = 0 ]
