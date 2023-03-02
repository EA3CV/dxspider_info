#
# List of connected users for use from a mobile app
#
# Use: musers (or mu)
#
# Copy in /spider/local_cmd/musers.pl
#
# Kin EA3CV, ea3cv@cronux.net
#
# 20230302 v1.3
#

use strict;
use warnings;

my $self = shift;

return 1 unless $self->priv >= 5;

my $tnow = time();
my $all_users = 0;
my @out = (" ", " List of Connected Users:", " ", " Callsign  R P  Type       Connection Time",
                                                  " --------  - -  ---------  ---------------");

foreach my $dxchan ( sort {$a->call cmp $b->call} DXChannel::get_all ) {
    my $call = $dxchan->call();
    my $type = $dxchan->is_node ? "NODE" : "USER";
    my $sort = "    ";
    my $isreg = reg($call) ?  "R" : " ";
    my $ispass = pass($call) ?  "P" : " ";
    my $name = $dxchan->user->name || " ";
    my $conn = $dxchan->conn;
    my $ip = '';
    my $time_on;

    if ($dxchan->is_node || $dxchan->is_rbn) {
        $sort = "DXSP" if $dxchan->is_spider;
        $sort = "CLX " if $dxchan->is_clx;
        $sort = "DXNT" if $dxchan->is_dxnet;
        $sort = "AR-C" if $dxchan->is_arcluster;
        $sort = "AK1A" if $dxchan->is_ak1a;
        $sort = "RBN " if $dxchan->is_rbn;
    } else {
        $sort = "LOCL" if $dxchan->conn->isa('IntMsg');
        $sort = "WEB " if $dxchan->is_web;
        $sort = "EXT " if $dxchan->conn->isa('ExtMsg');
    }

    if ($conn) {
        $ip = $dxchan->hostname;
        $ip = "AGW Port ($conn->{agwport})" if exists $conn->{agwport};
    }

    my $delta = $tnow - $dxchan->startt;
    $time_on = sprintf("%3d d%3d h %3d m", int($delta/(24*60*60)), int(($delta/(60*60))%24), int(($delta/60)%60));

    if ($type eq "USER") {
        push @out, sprintf(" %-9s $isreg $ispass  $type $sort $time_on", $call);
    }
}

$all_users = scalar DXChannel::get_all_users();

push @out, " ", " Total Users:  $all_users", " ";

return (1, @out);

sub reg {
    my $call = shift;
    $call = uc $call;
    my $ref = DXUser::get_current($call);
    return $ref && $ref->{registered} eq "1";
}

sub pass {
    my $call = shift;
    $call = uc $call;
    my $ref = DXUser::get_current($call);
    return defined $ref && defined $ref->{passwd};
}
