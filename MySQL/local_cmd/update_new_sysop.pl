#!/usr/bin/perl

#
#  update_new_sysop.pl — Recreate sysop and alias user entries for DXSpider
#
#  Description:
#    This script deletes and recreates the DXSpider sysop (mycall) and alias (myalias)
#    users using the values defined in DXVars.pm. It allows specifying the password,
#    registered flag and K flag for both calls.
#
#  Variables required in DXVars.pm:
#    $mycall         - Sysop callsign (e.g. "EA4URE-6")
#    $mycall_pass    - Password string
#    $mycall_reg     - Registered flag 1
#    $mycall_K       - K flag 1
#    $myalias        - Alias callsign (e.g. "EA4URE")
#    $myalias_pass   - Password string
#    $myalias_reg    - Registered flag 1
#    $myalias_K      - K flag 1
#
#  Install:
#    Copy to: /spider/local_cmd/update_new_sysop.pl
#
#  WARNING:
#    Must be run only when the cluster is down (cluster.pl stopped)
#
#  Author   : Kin EA3CV (ea3cv@cronux.net)
#  Version  : 20250626 v2.0
#

BEGIN {
    $root = "/spider";
    $root = $ENV{'DXSPIDER_ROOT'} if $ENV{'DXSPIDER_ROOT'};
    unshift @INC, "$root/perl";
    unshift @INC, "$root/local";
}

use DXVars;
use SysVar;
use DXUser;
use DXUtil;

sub create_it {
    my $ref;

    while ($ref = DXUser::get(uc $mycall)) {
        print "old call $mycall deleted\n";
        $ref->del();
    }

    my $self = DXUser->new(uc $mycall);
    $self->{alias}    = uc $myalias;
    $self->{name}     = $myname;
    $self->{qth}      = $myqth;
    $self->{qra}      = uc $mylocator;
    $self->{lat}      = $mylatitude;
    $self->{long}     = $mylongitude;
    $self->{email}    = $myemail;
    $self->{bbsaddr}  = $mybbsaddr;
    $self->{homenode} = uc $mycall;
    $self->{sort}     = 'S';
    $self->{priv}     = 9;
    $self->{lastin}   = 0;
    $self->{dxok}     = 1;
    $self->{annok}    = 1;

    $self->{passwd}     = $mycall_pass if defined $mycall_pass;
    $self->{registered} = $mycall_reg  if defined $mycall_reg;
    $self->{K}          = $mycall_K    if defined $mycall_K;

    $self->close();
    print "new call $mycall added\n";

    while ($ref = DXUser::get($myalias)) {
        print "old call $myalias deleted\n";
        $ref->del();
    }

    $self = DXUser->new(uc $myalias);
    $self->{name}     = $myname;
    $self->{qth}      = $myqth;
    $self->{qra}      = uc $mylocator;
    $self->{lat}      = $mylatitude;
    $self->{long}     = $mylongitude;
    $self->{email}    = $myemail;
    $self->{bbsaddr}  = $mybbsaddr;
    $self->{homenode} = uc $mycall;
    $self->{sort}     = 'U';
    $self->{priv}     = 9;
    $self->{lastin}   = 0;
    $self->{dxok}     = 1;
    $self->{annok}    = 1;
    $self->{lang}     = 'en';
    $self->{group}    = [qw(local #9000)];

    $self->{passwd}     = $myalias_pass if defined $myalias_pass;
    $self->{registered} = $myalias_reg  if defined $myalias_reg;
    $self->{K}          = $myalias_K    if defined $myalias_K;

    $self->close();
    print "new call $myalias added\n";
}

die "\$myalias \& \$mycall are the same ($mycall)!, they must be different (hint: make \$mycall = '${mycall}-2';).\n"
    if $mycall eq $myalias;

$lockfn = "$main::local_data/cluster.lck";
if (-e $lockfn) {
    open(CLLOCK, "$lockfn") or die "Can't open Lockfile ($lockfn) $!";
    my $pid = <CLLOCK>;
    chomp $pid;
    die "Sorry, Lockfile ($lockfn) and process $pid exist, a cluster is running\n" if kill 0, $pid;
    close CLLOCK;
}

DXUser::init(1);
create_it();
DXUser::finish();
print "Update of $myalias on cluster $mycall successful\n";
exit(0);
