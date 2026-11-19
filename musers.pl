#
#  musers.pl — List connected DXSpider users
#
#  Description:
#    This script lists all connected users with flags for
#    registration and password, plus connection type and uptime.
#
#  Usage:
#    From DXSpider shell: musers   (or create alias 'mu')
#
#  Installation:
#    Save as: /spider/local_cmd/musers.pl
#
#  Author  Kin EA3CV (ea3cv@cronux.net)
#  Version 20261119 v2.1
#

use strict;
use warnings;

my $SHOW_IP = 1;    # Installer preserves the current installed setting.

my $self = shift;
return 1 unless $self->priv >= 1;
my $now = time();
my @out = (
    ' ',
    ' List of Connected Users:',
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
my ( $total, $registered, $with_passwd, $web, $local, $external ) = ( 0, 0, 0, 0, 0, 0 );

for my $ch ( sort { $a->call cmp $b->call } DXChannel::get_all_users() ) {
    my $call = $ch->call;
    my $r    = reg($call)  ? 'R' : ' ';
    my $p    = pass($call) ? 'P' : ' ';
    my $kind = 'USER';
    if ( $ch->conn && $ch->conn->isa('IntMsg') ) { $kind = 'USER LOCL'; $local++ }
    if ( $ch->conn && $ch->conn->isa('ExtMsg') ) { $kind = 'USER EXT';  $external++ }

    # Same classification as cmd/who.pl: WebCluster virtual user channels
    # do not necessarily return true from DXChannel::is_web().
    if ( $ch->is_web || ( $ch->isa('Web::UserChannel') && !$ch->{web_released} ) ) {
        $kind = 'USER WEB';
        $web++;
    }
    my $elapsed = $now - ( $ch->startt || $now );
    $elapsed = 0 if $elapsed < 0;
    my $uptime = sprintf( '%dd %02dh %02dm',
        int( $elapsed / 86400 ),
        int( $elapsed / 3600 ) % 24,
        int( $elapsed / 60 ) % 60 );
    my $row = sprintf( ' %-12s %1s %1s  %-9s  %-12s', $call, $r, $p, $kind, $uptime );
    $row .= '  ' . channel_ip($ch) if $SHOW_IP;
    push @out, $row;
    $total++;
    $registered++  if $r eq 'R';
    $with_passwd++ if $p eq 'P';
}
push @out, ' ',
    sprintf( ' Total: %d  Registered: %d  Password: %d', $total, $registered, $with_passwd ), ' ';
return ( 1, @out );

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
