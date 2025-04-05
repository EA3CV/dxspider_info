#
#  mnodes.pl — List connected nodes (excluding local)
#
#  Description:
#    This script lists all connected nodes (type "NODE") excluding
#    the local node itself, with their connection type and uptime.
#
#  Usage:
#    From DXSpider shell: mnodes   (or alias 'mn')
#
#  Installation:
#    Save as: /spider/local_cmd/mnodes.pl
#
#  Author   : Kin EA3CV (ea3cv@cronux.net)
#  Version  : 20250406 v1.5
#

use strict;
use warnings;

my ($self, $line) = @_;
return 1 unless $self->priv >= 5;

my $now = time();
my $localcall = $main::mycall;
my @nodes = grep { $_->is_node && $_->call ne $localcall } DXChannel::get_all();
my @out = (
    " ",
    " Connected DXSpider Nodes (excluding local):",
    " ",
    " Callsign     Type   ConnType   Uptime",
    " --------     -----  --------   -----------------"
);

foreach my $dxchan (sort { $a->call cmp $b->call } @nodes) {
    my $call = $dxchan->call;
    my $type = "NODE";
    my $conn_type = "????";

    if ($dxchan->is_spider)     { $conn_type = "DXSP"; }
    elsif ($dxchan->is_clx)     { $conn_type = "CLX";  }
    elsif ($dxchan->is_dxnet)   { $conn_type = "DXNT"; }
    elsif ($dxchan->is_arcluster){ $conn_type = "AR-C";}
    elsif ($dxchan->is_ak1a)    { $conn_type = "AK1A"; }
    elsif ($dxchan->is_ccluster){ $conn_type = "CCCL"; }

    my $delta = $now - $dxchan->startt;
    my $uptime = sprintf("%3dd %02dh %02dm",
        int($delta / 86400),
        int(($delta % 86400) / 3600),
        int(($delta % 3600) / 60)
    );

    push @out, sprintf(" %-12s %-6s %-9s %s", $call, $type, $conn_type, $uptime);
}

my $total = scalar(@nodes);
push @out, " ", " Total connected nodes: $total", " ";

return (1, @out);
