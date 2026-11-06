#!/usr/bin/env bash
# Ringkasan tshark untuk tangkapan bukti (jalan di lab). Keluaran dipakai untuk gambar.
D=${1:?dir}; cd "$D" || exit 1
P=all.pcap
echo '$ tshark -r all.pcap -d udp.port==2152,gtp -Y "udp.dstport==2152" -c 14'
printf '%-4s %-8s %-13s %-13s %-5s %-12s %-5s %s\n' No Waktu Sumber Tujuan UDP TEID Tipe QFI
timeout 40 tshark -r $P -n -d udp.port==2152,gtp -Y 'udp.dstport==2152' -c 14 -T fields \
  -e frame.number -e frame.time_relative -e ip.src -e ip.dst -e udp.length -e gtp.teid -e gtp.message \
  -e gtp.ext_hdr.pdu_ses_con.qos_flow_id -E occurrence=f 2>/dev/null |
  awk -F'\t' '{printf "%-4s %-8.3f %-13s %-13s %-5s %-12s %-5s %s\n",$1,$2,$3,$4,$5,$6,$7,$8}'
echo
echo '$ tshark -r all.pcap -q -z conv,udp   (percakapan UDP di kabel)'
timeout 40 tshark -r $P -n -q -z conv,udp 2>/dev/null | sed -n '1,9p' | cut -c1-110
echo
echo '$ tshark -r all.pcap -Y "udp.dstport==2152" -T fields -e gtp.teid | sort -u | wc -l'
timeout 40 tshark -r $P -n -d udp.port==2152,gtp -Y 'udp.dstport==2152' -T fields -e gtp.teid 2>/dev/null | sort -u | wc -l
echo
echo '$ tshark ... -Y "udp.srcport==50000 || udp.dstport==50000"  (telemetri keluar papan)'
timeout 40 tshark -r $P -n -Y 'ip.src==192.168.0.20 && udp.dstport==50000' -T fields -e frame.time_relative -e udp.length -e data.data 2>/dev/null |
  python3 -c "
import sys,struct
NAME={1:'0x01 GLOBAL ',2:'0x02 per-TEID',3:'0x03 EVENT ',4:'0x04 PROTOKOL'}
n=0
for l in sys.stdin:
    r=l.rstrip('\n').split('\t')
    if len(r)<3 or not r[2]: continue
    b=bytes.fromhex(r[2].replace(':',''))
    if b[0]!=1: continue
    ts,ti,ul,dl,at,tb,dr=struct.unpack('>IIIIIQI',b[4:36])
    print('t=%7.3f  %s  ul_pps=%-4d dl_pps=%d  total_bytes=%d  drop=%d' % (float(r[0]),NAME[1],ul,dl,tb,dr)); n+=1
    if n>=8: break
"
