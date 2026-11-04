#!/usr/bin/perl
# Bangkitkan trafik UDP dari UE (dijalankan di netns ue1) lewat tun_srsue -> S1-U -> SGW-U/UPF.
# Campuran ukuran paket & port supaya histogram payload di dashboard tidak datar.
# Pakai: ip netns exec ue1 perl ue_traffic.pl <jumlah_paket> <pps>
use strict; use warnings; use IO::Socket::INET; use Time::HiRes qw(sleep time);
my ($n, $pps) = (shift // 500, shift // 100);
my $dst = $ENV{DST} // "10.45.0.1";          # gateway UPF (sisi core)
my @sizes = (64, 128, 256, 512, 1000);        # byte payload UDP
my @ports = (53, 123, 5060, 8000, 9);         # DNS, NTP, SIP, alt-http, discard
my @sock  = map { IO::Socket::INET->new(PeerAddr=>$dst, PeerPort=>$_, Proto=>"udp") or die "socket $_: $!" } @ports;
my $gap = 1.0/$pps; my $t0 = time; my $sent = 0;
for my $i (1..$n) {
    my $k = $i % scalar(@sizes);
    my $size = $sizes[$k];
    $sent++ if $sock[$k]->send(pack("N", $i) . ("X" x ($size-4)));
    my $d = ($t0 + $i*$gap) - time; sleep($d) if $d > 0;
}
printf "terkirim %d paket UDP, campuran %s B, tujuan %s dalam %.2f dtk (%.0f pps)\n",
       $sent, join("/", @sizes), $dst, time-$t0, $sent/(time-$t0);
