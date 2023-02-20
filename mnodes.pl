#
# List of connected nodes for use from a mobile app
#
# Use: mnodes (or mn)
#
# Copy in /spider/local_cmd
#
# Date:Manip must be installed
#    Debian (or similar): apt install libdate-manip-perl
#    Alternative: cpanm install Date:Manip
#
# Kin EA3CV, ea3cv@cronux.net
#
# 20220202 v1.0
#

use Date::Manip;
use strict;
use warnings;

my $self = shift;

return (1) unless $self->priv >= 5;

my $dxchan;
my @out;

push @out, " ";
push @out, " List of Connected Nodes:";
push @out, " ";
push @out, " Callsign   Type       Connection time";
push @out, " --------   ---------  ---------------";

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

        if ($type eq "NODE") {
                push @out, sprintf " %-10s $type $sort $time_on", $call;
        }
}

my $all_nodes = scalar DXChannel::get_all_nodes();

push @out, " ";
push @out, " Nodes:  $all_nodes";
push @out, " ";

return (1, @out);
