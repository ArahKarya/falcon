#!/usr/bin/env bash
# Uji terminal Setup: (1) baris mengalir SAAT proses berjalan (bukan setelah selesai), (2) keluaran iMPACT nyata diringkas,
# (3) rahasia/IMSI/jalur host disaring, (4) akses: hanya login, tidak ada di jalur publik, (5) kejadian link, (6) hanya baca.
# fpgactl PALSU meniru keluaran iMPACT asli (diambil dari /data/yayang/flash/prog_new2.log). Tidak menyentuh papan.
set -u
cd "$(dirname "$0")/../falcon/backend"
PY="${FALCON_PY:-python3}"
T=$(mktemp -d); export FALCON_USERS_FILE="$T/users.json"
OPW=$($PY auth.py add op1 operator | sed -n 's/.*: //p' | tail -1)
VPW=$($PY auth.py add vw1 viewer   | sed -n 's/.*: //p' | tail -1)

cat > "$T/fpgactl.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status) echo '{"jtag_cable": true, "eth_link": true, "host_ip": true, "bitstream_sha": "8bf0fc60", "board_ip": "192.168.0.20"}' ;;
  load)
    echo "[fpgactl] program 8bf0fc60 lewat iMPACT" >&2
    echo "iMPACT Version: Oct 13 2013 08:43:40"
    echo "Preference Table"
    echo "StartupClock         Auto_Correction"
    echo "Connecting to cable (Usb Port - USB21)."
    echo "File version of /data/xilinx/14.7/ISE_DS/ISE/bin/lin64/xusbdfwu.hex = 1030."
    sleep 1.2
    echo "Cable connection established."
    echo "Firmware version = 1303."
    sleep 1.2
    echo "Identifying chain contents...'0': : Manufacturer's ID = Xilinx xc5vlx50t, Version : 12"
    echo "INFO:iMPACT:501 - '1': Added Device xc5vlx50t successfully."
    echo "'1': Loading file '/data/yayang/falcon-bitstream/genesys_fpga.bit'"
    echo "Startup Clock has been changed to 'JtagClk' in the bitstream"
    echo "akun uji password=RAHASIA123 dan token: abcdef lalu Bearer eyJhbGciOi.xyz di /home/noz/rahasia IMSI 510119999999999"
    sleep 1.2
    echo "Programmed successfully."
    echo "[fpgactl] DONE pin OK" >&2
    [ -f "$FAKE_FAIL" ] && { echo "ERROR:iMPACT:583 - PROGRAM FAILED" >&2; exit 5; }
    echo "[fpgactl] telemetri masuk" >&2; exit 0 ;;
esac
EOF
chmod +x "$T/fpgactl.sh"

FALCON_FPGACTL="$T/fpgactl.sh" FAKE_FAIL="$T/fail" FALCON_HTTP_PORT=8401 FALCON_UDP_PORT=50401 FALCON_MODE=live \
  FALCON_DEMO_TRAFFIC="" FALCON_DEMO_TARGET=127.0.0.1:59999 $PY server.py > "$T/be.log" 2>&1 &
BE=$!; trap 'kill $BE 2>/dev/null; rm -rf "$T"' EXIT; sleep 2
B=http://127.0.0.1:8401; PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1 (dapat '$2', mau '$3')"; FAIL=$((FAIL+1)); fi; }
code(){ curl -s -o /dev/null -w "%{http_code}" "$@"; }
jq1(){ $PY -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
login(){ curl -s -c "$T/$1.jar" -X POST $B/api/login -d "{\"username\":\"$2\",\"password\":\"$3\"}" -o /dev/null; }
login op op1 "$OPW"; login vw vw1 "$VPW"
LOG(){ curl -s -b "$T/$1.jar" "$B/api/setup/log?since=${2:-0}"; }

# ---- A. akses
chk "A tanpa login -> 401"                         "$(code $B/api/setup/log)" 401
chk "A viewer boleh MELIHAT (GET)"                 "$(code -b $T/vw.jar $B/api/setup/log)" 200
chk "A viewer TIDAK boleh membersihkan -> 403"     "$(code -b $T/vw.jar -X POST $B/api/setup/log/clear)" 403
chk "A tanpa login: bersihkan -> 401"              "$(code -X POST $B/api/setup/log/clear)" 401
chk "A term.js hanya memanggil /api/setup/log*"     "$(curl -s -b $T/op.jar $B/static/term.js | grep -o "fetch('[^']*" | sed "s/fetch('//; s/[?].*//" | sort -u | tr '\n' ' ')" "/api/setup/log /api/setup/log/clear "
chk "A setup-fpga & setup-traffic memuat term.js"   "$(for u in fpga traffic; do curl -s -b $T/op.jar $B/setup/$u | grep -c 'static/term.js'; done | tr -d '\n')" 11
chk "A dashboard publik TIDAK memuat term.js"      "$(curl -s -b $T/op.jar $B/ | grep -c 'term.js')" 0
chk "A hanya baca: tak ada endpoint tulis perintah" "$(code -b $T/op.jar -X POST $B/api/setup/log -d '{\"cmd\":\"ls\"}')" 405

# ---- B. catatan awal sistem
chk "B baris awal 'Backend FALCON aktif'"          "$(LOG op | jq1 "any('Backend FALCON aktif' in r['text'] for r in d['rows'])")" True

# ---- C. alur HIDUP: baris muncul SELAGI proses berjalan
LAST=$(LOG op | jq1 "d['last']")
chk "C pemuatan dimulai -> 200"                    "$(code -b $T/op.jar -X POST $B/api/fpga/load)" 200
sleep 1.6                                          # fpgactl masih jalan (total ~3,6 dtk)
MID=$(LOG op $LAST)
chk "C SELAGI berjalan: sudah ada baris 'kabel'"   "$(echo "$MID" | jq1 "any('JTAG' in r['text'] or 'kabel' in r['text'].lower() for r in d['rows'])")" True
chk "C SELAGI berjalan: belum ada 'BERHASIL'"      "$(echo "$MID" | jq1 "any('BERHASIL' in r['text'] for r in d['rows'])")" False
chk "C SELAGI berjalan: job masih 'loading'"       "$(curl -s -b $T/op.jar $B/api/setup/fpga | jq1 "d['loader']['job']['phase']")" loading
sleep 3.5
ALL=$(LOG op $LAST)
chk "C selesai: ada 'Pemrograman FPGA BERHASIL'"   "$(echo "$ALL" | jq1 "any('BERHASIL' in r['text'] for r in d['rows'])")" True
chk "C selesai: ada 'Pin DONE tinggi'"             "$(echo "$ALL" | jq1 "any('DONE tinggi' in r['text'] for r in d['rows'])")" True
chk "C selesai: ada 'xc5vlx50t terdeteksi'"        "$(echo "$ALL" | jq1 "any('xc5vlx50t terdeteksi' in r['text'] for r in d['rows'])")" True
chk "C selesai: penanda 'SELESAI'"                 "$(echo "$ALL" | jq1 "any('SELESAI' in r['text'] for r in d['rows'])")" True
chk "C operator pemicu tercatat"                   "$(echo "$ALL" | jq1 "any('op1' in r['text'] and 'Muat gateware' in r['text'] for r in d['rows'])")" True

# ---- D. kebisingan iMPACT dibuang, urutan benar
chk "D tabel preferensi iMPACT disaring"           "$(echo "$ALL" | jq1 "any('StartupClock         Auto' in r['text'] or 'Preference Table' in r['text'] for r in d['rows'])")" False
chk "D 'File version of' disaring"                 "$(echo "$ALL" | jq1 "any('File version of' in r['text'] for r in d['rows'])")" False
chk "D id naik monoton tanpa duplikat"             "$(echo "$ALL" | jq1 "[r['id'] for r in d['rows']]==sorted(set(r['id'] for r in d['rows']))")" True
chk "D tahap kabel sebelum BERHASIL (urutan nyata)" "$(echo "$ALL" | jq1 "[i for i,r in enumerate(d['rows']) if 'JTAG tersambung' in r['text']][0] < [i for i,r in enumerate(d['rows']) if 'BERHASIL' in r['text']][0]")" True

# ---- E. PENYARINGAN rahasia / IMSI / jalur
RAW=$(LOG op 0 | tr -d '\n')
chk "E sandi tidak bocor"                          "$(echo "$RAW" | grep -c 'RAHASIA123')" 0
chk "E token tidak bocor"                          "$(echo "$RAW" | grep -c 'abcdef')" 0
chk "E bearer tidak bocor"                         "$(echo "$RAW" | grep -c 'eyJhbGciOi')" 0
chk "E IMSI penuh tidak bocor"                     "$(echo "$RAW" | grep -c '510119999999999')" 0
chk "E IMSI tersamar 510************"              "$(echo "$RAW" | grep -c '510\*\*\*\*\*\*\*\*\*\*\*\*')" 1
chk "E jalur /home/noz dipendekkan"                "$(echo "$RAW" | grep -c '/home/noz')" 0
chk "E jalur /data/xilinx dipendekkan"             "$(echo "$RAW" | grep -c '/data/xilinx')" 0

# ---- F. kegagalan tampil sebagai ERROR
touch "$T/fail"; LAST=$(LOG op | jq1 "d['last']")
code -b $T/op.jar -X POST $B/api/fpga/load >/dev/null; sleep 5
F=$(LOG op $LAST)
chk "F kegagalan: baris ber-level err"             "$(echo "$F" | jq1 "any(r['lvl']=='err' for r in d['rows'])")" True
chk "F kegagalan: penanda GAGAL + alasan operator" "$(echo "$F" | jq1 "any('GAGAL' in r['text'] and 'iMPACT' in r['text'] for r in d['rows'])")" True
rm -f "$T/fail"

# ---- G. kejadian otomatis: link papan terhubung lalu putus
LAST=$(LOG op | jq1 "d['last']")
$PY - <<EOF
import socket,sys,time
sys.path.insert(0,"$PWD/..")
from shared import contract as C
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
for _ in range(4): s.sendto(C.pack_global(1,0,10,0,0,100,0),("127.0.0.1",50401)); time.sleep(0.3)
EOF
sleep 2
chk "G papan TERHUBUNG tercatat"                   "$(LOG op $LAST | jq1 "any('TERHUBUNG' in r['text'] and r['src']=='link' for r in d['rows'])")" True
sleep 5
chk "G papan TERPUTUS tercatat (setelah diam)"     "$(LOG op $LAST | jq1 "any('TERPUTUS' in r['text'] for r in d['rows'])")" True
N1=$(LOG op $LAST | jq1 "sum(1 for r in d['rows'] if r['src']=='link')")
sleep 4
N2=$(LOG op $LAST | jq1 "sum(1 for r in d['rows'] if r['src']=='link')")
chk "G tidak membanjiri: tak ada baris link baru saat status tetap" "$([ "$N1" = "$N2" ] && echo sama || echo beda)" sama

# ---- H. filter sumber + batas ring buffer
chk "H filter src=fpga hanya sumber fpga"          "$(curl -s -b $T/op.jar "$B/api/setup/log?src=fpga" | jq1 "all(r['src']=='fpga' for r in d['rows']) and len(d['rows'])>0")" True
chk "H src tak dikenal diabaikan (tidak error)"    "$(code -b $T/op.jar "$B/api/setup/log?src=../../etc/passwd")" 200
chk "H bersihkan oleh operator"                    "$(code -b $T/op.jar -X POST $B/api/setup/log/clear)" 200
chk "H setelah bersih tinggal 1 baris catatan"     "$(LOG op | jq1 "len(d['rows'])")" 1

echo "---- $PASS lulus, $FAIL gagal"; [ "$FAIL" = 0 ]
