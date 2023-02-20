#
# List of connected users for use from a mobile app
#
# Use: musers (or mu)
#
# Copy in /spider/local_cmd/musers.pl
#
# Date:Manip must be installed
#    Debian (or similar): apt install libdate-manip-perl
#    Alternative: cpanm install Date:Manip
#
# Kin EA3CV, ea3cv@cronux.net
#
# 20220203 v1.1
#

use Date::Manip;
use strict;
use warnings;

my $self = shift;

return (1) unless $self->priv >= 5;

my $dxchan;
my @out;

push @out, " ";
push @out, " List of Connected Users:";
push @out, " ";
push @out, " Callsign  R  Type       Connection Time";
push @out, " --------  -  ---------  ---------------";

my $tnow = time();

foreach $dxchan ( sort {$a->call cmp $b->call} DXChannel::get_all ) {
        my $call = $dxchan->call();
        my $tconn = $dxchan->startt;
        my $type = $dxchan->is_node ? "NODE" : "USER";
        my $sort = "    ";

        if ($dxchan->is_node) {
                $sort = "DXSP" if $dxchan->is_spider;
                $sort = "CLX " if $dxchan->is_clx;
                $sort = "DXNT" if $dxchan->is_dxnet;
                $sort = "AR-C" if $dxchan->is_arcluster;
                $sort = "AK1A" if $dxchan->is_ak1a;
        } else {
                $sort = "LOCL" if $dxchan->conn->isa('IntMsg');
                $sort = "WEB " if $dxchan->is_web;
                $sort = "EXT " if $dxchan->conn->isa('ExtMsg');
        }

        my $isreg = " ";
        if ($dxchan->isregistered) {
                $isreg = "R";
        }

        my $name = $dxchan->user->name || " ";
        my $conn = $dxchan->conn;
        my $ip = '';

        if ($conn) {
                $ip = $dxchan->hostname;
                $ip = "AGW Port ($conn->{agwport})" if exists $conn->{agwport};
        }

	my $date1 = ParseDate($tnow);
	my $date2 = ParseDate($tconn);
	my $delta = DateCalc($date2,$date1, \my $err, 1);
	$delta = Delta_Format($delta, "%dv %hv %mv");
	my ($d, $h, $m) = split(' ', $delta);
        my $time_on = sprintf("%3d d%3d h %3d m", $d, $h, $m);

        if ($type eq "USER") {
                push @out, sprintf " %-9s $isreg  $type $sort $time_on", $call;
        }
}

my $all_users = scalar DXChannel::get_all_users();

push @out, " ";
push @out, " Users:  $all_users";
push @out, " ";

return (1, @out);
