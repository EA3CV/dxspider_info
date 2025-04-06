#
#  mnodes.pl — List connected nodes
#
#  Description:
#    This script lists all connected nodes, placing the local node first,
#    followed by other remote nodes (sorted), and then RBN nodes at the end, separated.
#
#  Usage:
#    From DXSpider shell: mnodes   (or alias 'mn')
#
#  Installation:
#    Save as: /spider/local_cmd/mnodes.pl
#
#  Author   : Kin EA3CV ea3cv@cronux.net
#  Version  : 20250406 v1.7
#

use strict;
use warnings;

my ($self, $line) = @_;
return 1 unless $self->priv >= 5;

my $now = time();
my $localcall = $main::mycall;

my $local_node;
my @nodes;
my @rbn_nodes;

foreach my $dxchan (DXChannel::get_all()) {
    next unless $dxchan->is_node || $dxchan->is_rbn;

    if ($dxchan->is_rbn) {
        push @rbn_nodes, $dxchan;
    } elsif ($dxchan->call eq $localcall) {
        $local_node = $dxchan;
    } else {
        push @nodes, $dxchan;
    }
}

my @out = (
    " ",
    " List of Connected Nodes:",
    " ",
    " Callsign  R P  Type       Connection Time",
    " --------  - -  ---------  ---------------"
);

# Mostrar primero el nodo local (sin afectar al contador)
push @out, format_node($local_node, $now) if $local_node;

# Luego los nodos remotos ordenados
foreach my $dxchan (sort { $a->call cmp $b->call } @nodes) {
    push @out, format_node($dxchan, $now);
}

# Luego los RBN si los hay
if (@rbn_nodes) {
    push @out, " ";
    foreach my $dxchan (sort { $a->call cmp $b->call } @rbn_nodes) {
        push @out, format_node($dxchan, $now, "RBN ");
    }
}

# Contador final: solo nodos remotos
my $total = scalar(@nodes);
push @out, " ", " Total Nodes:  $total", " ";

return (1, @out);

# --- Subrutinas auxiliares ---

sub format_node {
    my ($dxchan, $now, $force_sort) = @_;

    my $call = $dxchan->call;
    my $isreg  = reg($call)  ? "R" : " ";
    my $ispass = pass($call) ? "P" : " ";
    my $sort   = "    ";

    $sort = $force_sort if defined $force_sort;
    unless ($force_sort) {
        $sort = "DXSP" if $dxchan->is_spider;
        $sort = "CLX "  if $dxchan->is_clx;
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
