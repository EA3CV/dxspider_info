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
#  Author   : Kin EA3CV ea3cv@cronux.net
#  Version  : 20250406 v1.6
#

use strict;
use warnings;

my ($self, $line) = @_;
return 1 unless $self->priv >= 5;

my $now = time();
my $localcall = $main::mycall;

my @nodes;
my @rbn_nodes;

foreach my $dxchan (DXChannel::get_all()) {
    next if $dxchan->call eq $localcall;

    if ($dxchan->is_rbn) {
        push @rbn_nodes, $dxchan;
    } elsif ($dxchan->is_node) {
        push @nodes, $dxchan;
    }
}

my @out = (
    " ",
    " List of Connected Nodes (excluding local):",
    " ",
    " Callsign  R P  Type       Connection Time",
    " --------  - -  ---------  ---------------"
);

foreach my $dxchan (sort { $a->call cmp $b->call } @nodes) {
    push @out, format_node($dxchan, $now);
}

if (@rbn_nodes) {
    push @out, " ";
    foreach my $dxchan (sort { $a->call cmp $b->call } @rbn_nodes) {
        push @out, format_node($dxchan, $now, "RBN ");
    }
}

my $total = @nodes + @rbn_nodes - 1;
push @out, " ", " Total Nodes:  $total", " ";

return (1, @out);

# Subrutina para formato de línea
sub format_node {
    my ($dxchan, $now, $force_sort) = @_;

    my $call = $dxchan->call;
    my $isreg  = reg($call)  ? "R" : " ";
    my $ispass = pass($call) ? "P" : " ";
    my $sort   = "    ";

    $sort = $force_sort if defined $force_sort;
    unless ($sort =~ /\S/) {
        $sort = "DXSP" if $dxchan->is_spider;
        $sort = "CLX " if $dxchan->is_clx;
        $sort = "DXNT" if $dxchan->is_dxnet;
        $sort = "AR-C" if $dxchan->is_arcluster;
        $sort = "AK1A" if $dxchan->is_ak1a;
        $sort = "CCCL" if $dxchan->is_ccluster;
    }

    my $delta = $now - $dxchan->startt;
    my $time_on = sprintf("%3d d%3d h %3d m",
        int($delta / 86400),
        int(($delta % 86400) / 3600),
        int(($delta % 3600) / 60)
    );

    return sprintf(" %-9s  $isreg $ispass  NODE $sort $time_on", $call);
}

sub reg {
    my $call = shift;
    my $ref = DXUser::get_current(uc $call);
    return defined $ref && $ref->{registered} eq "1";
}

sub pass {
    my $call = shift;
    my $ref = DXUser::get_current(uc $call);
    return defined $ref && defined $ref->{passwd};
}
