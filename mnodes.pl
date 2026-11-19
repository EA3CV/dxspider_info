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
#  Author  Kin EA3CV ea3cv@cronux.net
#  Version 2026119 v2.1
#

use strict;
use warnings;

my $SHOW_IP = 1;    # Installer preserves the current installed setting.

my ( $self, $line ) = @_;
return 1 unless $self->priv >= 1;
my $now = time();
my ( $local, @remote, @rbn );
for my $ch ( DXChannel::get_all() ) {
    next unless $ch->is_node || $ch->is_rbn;
    if    ( $ch->is_rbn )                { push @rbn, $ch }
    elsif ( $ch->call eq $main::mycall ) { $local = $ch }
    else                                 { push @remote, $ch }
}
my @out = (
    ' ',
    ' List of Connected Nodes:',
    ' ',
    sprintf(
        ' %-12s %1s %1s  %-9s  %-12s%s',
        'Callsign', 'R', 'P', 'Type', 'Connected', $SHOW_IP ? '  IP' : ''
    ),
    sprintf(
        ' %-12s %1s %1s  %-9s  %-12s%s',
        '-' x 12, '-', '-', '-' x 9, '-' x 12, $SHOW_IP ? '  ' . ( '-' x 15 ) : ''
    ),
);
my @all = (
    defined($local) ? ($local) : (),
    sort { $a->call cmp $b->call } @remote,
    sort { $a->call cmp $b->call } @rbn
);
push @out, format_node( $local, $now, $SHOW_IP ) if defined $local;
push @out, map { format_node( $_, $now, $SHOW_IP ) } sort { $a->call cmp $b->call } @remote;
if (@rbn) {
    push @out, ' ' if defined($local) || @remote;
    push @out, map { format_node( $_, $now, $SHOW_IP ) } sort { $a->call cmp $b->call } @rbn;
}
my ( $registered, $with_passwd ) = ( 0, 0 );
for my $ch (@all) {
    $registered++  if reg( $ch->call );
    $with_passwd++ if pass( $ch->call );
}
push @out, ' ',
    sprintf(
    ' Total: %d  Local: %d  Remote: %d  RBN: %d  Registered: %d  Password: %d',
    scalar(@all),    defined($local) ? 1 : 0,
    scalar(@remote), scalar(@rbn), $registered, $with_passwd
    ),
    ' ';
return ( 1, @out );

sub format_node {
    my ( $ch, $now, $show_ip ) = @_;
    my $call = $ch->call;
    my $r    = reg($call)  ? 'R' : ' ';
    my $p    = pass($call) ? 'P' : ' ';
    my $kind = 'NODE';
    if ( $ch->is_rbn ) { $kind = 'NODE RBN' }
    else {
        $kind = 'NODE DXSP' if $ch->is_spider;
        $kind = 'NODE CLX'  if $ch->is_clx;
        $kind = 'NODE DXNT' if $ch->is_dxnet;
        $kind = 'NODE AR-C' if $ch->is_arcluster;
        $kind = 'NODE AK1A' if $ch->is_ak1a;
        $kind = 'NODE CCCL' if $ch->is_ccluster;
    }
    my $elapsed = $now - ( $ch->startt || $now );
    $elapsed = 0 if $elapsed < 0;
    my $uptime = sprintf( '%dd %02dh %02dm',
        int( $elapsed / 86400 ),
        int( $elapsed / 3600 ) % 24,
        int( $elapsed / 60 ) % 60 );
    my $row = sprintf( ' %-12s %1s %1s  %-9s  %-12s', $call, $r, $p, $kind, $uptime );
    $row .= '  ' . channel_ip($ch) if $show_ip;
    return $row;
}

sub reg {
    my $ref = DXUser::get_current( uc shift );
    return defined $ref && defined $ref->{registered} && $ref->{registered} eq '1';
}

sub pass {
    my $ref = DXUser::get_current( uc shift );
    return defined $ref && defined $ref->{passwd} && length $ref->{passwd};
}

sub channel_ip {
    my $ip = shift->{hostname};
    return defined $ip && length $ip ? $ip : '-';
}
