#!/usr/bin/env bash
# Verifikasi simulator 5G di PAPAN (jalan di lab). Bandingkan byte yang dikirim backend vs yang DIHITUNG gateware.
# Memakai akun operator sementara 'tmp-verif' yang dibuat & dihapus skrip ini; sandi acak tidak disimpan.
set -u
BE=/data/yayang/falcon-v12/falcon/backend
PY=/data/yayang/falcon-v12/.venv/bin/python
B=http://127.0.0.1:8082
export FALCON_USERS_FILE=/data/yayang/.falcon/users.json
J=$(mktemp)
cleanup(){
  rm -f "$J"
  $PY -c "
import json,os
p=os.environ['FALCON_USERS_FILE']; d=json.load(open(p)); d.pop('tmp-verif',None)
json.dump(d,open(p,'w'),indent=2); os.chmod(p,0o600)"
}
trap cleanup EXIT
PW=$(cd $BE && $PY auth.py add tmp-verif operator | sed -n 's/.*: //p' | tail -1)
curl -s -c "$J" -X POST $B/api/login -d "{\"username\":\"tmp-verif\",\"password\":\"$PW\"}" -o /dev/null
H='content-type: application/json'
jf(){ $PY -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
glob(){ curl -s $B/api/stats/global; }

curl -s -b "$J" -X POST $B/api/traffic/stop -o /dev/null; sleep 5
echo "== sebelum: pps papan=$(glob | jf "d.get('uplink_pps',0)+d.get('downlink_pps',0)") (harus ~0)"
B0=$(glob | jf "d.get('total_bytes',0)")
echo "== start simulator 5G: 500 pps, 48 UE, campuran, burst 1.0; aktif 15 dtk lalu jeda"
curl -s -b "$J" -X POST $B/api/traffic/start -H "$H" -d '{"source":"sim-5g","pps":500,"on_s":15,"off_s":600,"sim5g":{"preset":"campuran","ues":48,"burst":1.0}}' | jf "d['ok']"
sleep 8
echo "-- tengah jalan: ul_pps papan=$(glob | jf "d.get('uplink_pps')") (target 500; burst memodulasi)"
sleep 14                                   # lewat 15 dtk aktif -> fase jeda, + 1 emit GLOBAL
S=$(curl -s -b "$J" $B/api/sim5g)
SB=$(echo "$S" | jf "d['sent_bytes']"); SP=$(echo "$S" | jf "d['sent_pkts']")
DS=$(curl -s $B/api/demo | jf "d['sent']")
sleep 6
G=$(glob | jf "d.get('total_bytes',0)")
echo "$S" | jf "'per_app: '+', '.join('%s=%d'%(a,v['pkts']) for a,v in sorted(d['per_app'].items(), key=lambda x:-x[1]['pkts']))"
echo "== generator : paket dibuat=$SP  byte=$SB  | sendto sukses (demo.sent)=$DS (sejak backend hidup, kumulatif)"
echo "== papan     : total_bytes (delta sejak awal)=$((G-B0))"
$PY -c "
sent=$SB; seen=$G-$B0
print('== selisih papan - generator = %d byte (%.4f%%)' % (seen-sent, (seen-sent)/sent*100 if sent else 0))
print('== HASIL:', 'EKSAK' if seen==sent else ('COCOK (<0.01%)' if sent and abs(seen-sent)/sent < 1e-4 else 'TIDAK COCOK'))"
echo "== papan menganggur saat jeda: ul_pps=$(glob | jf "d.get('uplink_pps')") (harus 0)"
echo "== TEID di papan: $(curl -s $B/api/stats/teid | jf "len(d)") (generator: $(echo "$S" | jf "d['sessions']") sesi)"
curl -s $B/api/stats/teid | jf "'\n'.join('   '+str({k:x[k] for k in list(x)[:6]}) for x in d[:3])" 2>&1 | head -5
echo "== lencana publik: sumber=$(curl -s $B/api/demo | jf "d['source']") aktif=$(curl -s $B/api/demo | jf "d['active']")"
curl -s -b "$J" -X POST $B/api/traffic/stop -o /dev/null
echo "== stop. akun sementara dihapus saat keluar."
