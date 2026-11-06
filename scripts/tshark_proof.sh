#!/usr/bin/env bash
# Bukti trafik di KABEL (tshark): masuk ke papan (UDP 2152) vs telemetri keluar papan (UDP 50000).
# Jalan di lab. Tangkap dua arah di enp2s0, lalu analisis. Tidak mengubah apa pun di papan/backend.
set -u
IF=enp2s0; DUR=${1:-10}; D=/data/yayang/tshark-$(date +%H%M%S); mkdir -p $D
BOARD=192.168.0.20; HOST=192.168.0.101
echo "== demo: $(curl -s localhost:8082/api/demo | python3 -c "import sys,json;d=json.load(sys.stdin);print('sumber',d['source'],'aktif',d['active'],'pps',d['pps'])")"
# sinkron jadwal demo: tunggu fase aktif (maks 140 dtk) agar tangkapan tak jatuh di jeda
for i in $(seq 1 140); do
  A=$(curl -s localhost:8082/api/demo | python3 -c "import sys,json;d=json.load(sys.stdin);import time;print(1 if d['active'] and d['next_flip']-time.time()>${DUR}+3 else 0)")
  [ "$A" = 1 ] && break; [ $i = 1 ] && echo "   (menunggu fase aktif demo...)"; sleep 1
done
echo "== tangkap ${DUR} dtk di $IF -> $D"
# tcpdump -Z root: tshark/dumpcap menjatuhkan hak akses lalu gagal menulis ke /data (Permission denied)
sudo -n timeout $((DUR+3)) tcpdump -i $IF -n -Z root -s 0 -w $D/all.pcap "host $BOARD" 2>/dev/null
sudo -n chown $(id -u):$(id -g) $D/all.pcap 2>/dev/null
[ -s $D/all.pcap ] || { echo "GAGAL: tangkapan kosong/tidak terbentuk (bukan berarti tak ada trafik)"; exit 1; }
ls -la $D/all.pcap | awk '{print "   berkas:",$5,"byte"}'

echo; echo "== [1] MASUK ke papan: $HOST -> $BOARD udp/2152 (GTP-U)"
tshark -r $D/all.pcap -n -Y "ip.src==$HOST && ip.dst==$BOARD && udp.dstport==2152" -T fields -e frame.time_relative -e udp.length -E occurrence=f 2>/dev/null > $D/in.tsv
python3 - <<EOF
import collections
rows=[l.split("\t") for l in open("$D/in.tsv").read().splitlines() if l.strip()]
n=len(rows); ul=[int(r[1].split(",")[0]) for r in rows]; udp_payload=sum(x-8 for x in ul)
print("   paket        :", n)
print("   laju rata2   : %.1f pps" % (n/$DUR))
print("   byte payload UDP (=GTP-U, yang dihitung papan): %d" % udp_payload)
print("   ukuran UDP   : min %d  rata %.0f  maks %d" % (min(ul),sum(ul)/n,max(ul)))
print("   ada fragmen IP? (udp>1472 tak ada):", "tidak" if max(ul)-8<=1472 else "YA")
EOF
echo "   --- decode GTP-U (tshark): TEID & QFI paket pertama"
tshark -r $D/all.pcap -n -Y "udp.dstport==2152" -d udp.port==2152,gtp -T fields -e gtp.teid -e gtp.message -e gtp.ext_hdr.pdu_ses_con.qos_flow_id -e gtp.flags 2>/dev/null | head -3 | sed 's/^/     /'
tshark -r $D/all.pcap -n -Y "udp.dstport==2152" -d udp.port==2152,gtp -T fields -e gtp.teid 2>/dev/null | sort | uniq -c | sort -rn > $D/teid_in.txt
echo "   TEID unik masuk: $(wc -l < $D/teid_in.txt)  | 5 teratas:"; head -5 $D/teid_in.txt | sed 's/^/     /'

echo; echo "== [2] KELUAR dari papan: $BOARD -> $HOST udp/50000 (telemetri)"
tshark -r $D/all.pcap -n -Y "ip.src==$BOARD && ip.dst==$HOST && udp.srcport!=0 && udp.dstport==50000" -T fields -e frame.time_relative -e udp.length -e data.data 2>/dev/null > $D/out.tsv
python3 - <<EOF
import collections
rows=[l.split("\t") for l in open("$D/out.tsv").read().splitlines() if l.strip()]
types=collections.Counter(); glob=[]
for r in rows:
    if len(r)<3 or not r[2]: continue
    b=bytes.fromhex(r[2].replace(":",""))
    types[b[0]]+=1
    if b[0]==1 and len(b)>=24: glob.append(b)
NAME={1:"0x01 global",2:"0x02 per-TEID",3:"0x03 event",4:"0x04 protokol"}
print("   datagram     :", len(rows))
print("   per tipe     :", {NAME.get(k,k):v for k,v in sorted(types.items())})
import struct
# kontrak (falcon/shared/contract.py): header 4B lalu ">IIIIIQI" = ts,total_imsi,ul_pps,dl_pps,active_teid,total_bytes,drop
for b in glob[:6]:
    ts,ti,ul,dl,at,tb,dr=struct.unpack(">IIIIIQI", b[4:4+32])
    print("   global: ul_pps=%-4d dl_pps=%d total_bytes=%d total_imsi=%d active_teid=%d drop=%d" % (ul,dl,tb,ti,at,dr))
EOF
echo; echo "== [3] ARP/lain di kabel:"; tshark -r $D/all.pcap -n -q -z io,phs 2>/dev/null | grep -E "eth|ip |udp|arp|gtp|data" | head -8
echo; echo "== berkas: $D (all.pcap, in.tsv, out.tsv, teid_in.txt)"
