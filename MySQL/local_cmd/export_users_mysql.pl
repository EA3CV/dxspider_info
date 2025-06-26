#!/usr/bin/perl

#
#  export_users_mysql.pl — Export DXSpider users/nodes from MySQL in JSON and SQL formats
#
#  Description:
#    This script exports all registered users/nodes from a MySQL/MariaDB backend
#    used by DXSpider into two formats:
#      - A full SQL database backup: users_backup.sql
#      - A JSON-formatted flat file: user_json
#
#    It replaces the original `export_users` command when the database backend
#    is set to MySQL (`$db_backend = 'mysql'`).
#
#  Usage:
#    DXSpider command:
#      export_users_mysql
#
#    The output files are saved under: `/spider/local_data/`
#
#  Installation:
#    Save as: /spider/spider/local_cmd/export_users_mysql.pl
#
#  Requirements:
#    - Patched versions of:
#        DXUser.pm      (must support `$main::db_backend = 'mysql'`)
#        DB_Mysql.pm
#
#  Output:
#    - /spider/local_data/users_backup.sql
#    - /spider/local_data/user_json
#
#  Author  : Kin EA3CV (ea3cv@cronux.net)
#  Version : 20250618 v1.0
#
#  License : This software is released under the GNU General Public License v3.0 (GPLv3)
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
