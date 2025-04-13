#
# module to timed tasks
#
# Copyright (c) 1998 - Dirk Koopman G1TLH
#
# Modify by Kin EA3CV
# 20250413 v0.0
#

package DXCron;

use DXVars;
use DXUtil;
use DXM;
use DXDebug;
use IO::File;
use DXLog;
use Time::HiRes qw(gettimeofday tv_interval);
use DXSubprocess;

use strict;

use vars qw{@crontab @lcrontab @scrontab $mtime $lasttime $lastmin $use_localtime};

$mtime = 0;
$lasttime = 0;
$lastmin = 0;
$use_localtime = 0;

my $fn = "$main::cmd/crontab";
my $localfn = "$main::localcmd/crontab";

# cron initialisation / reading in cronjobs
sub init
{
        if ((-e $localfn && -M $localfn < $mtime) || (-e $fn && -M $fn < $mtime) || $mtime == 0) {
                my $t;

                # first read in the standard one
                if (-e $fn) {
                        $t = -M $fn;

                        @scrontab = cread($fn);
                        $mtime = $t if  !$mtime || $t <= $mtime;
                }

                # then read in any local ones
                if (-e $localfn) {
                        $t = -M $localfn;

                        @lcrontab = cread($localfn);
                        $mtime = $t if $t <= $mtime;
                }
                @crontab = (@scrontab, @lcrontab);
        }
}

# read in a cron file
sub cread
{
        my $fn = shift;
        my $fh = new IO::File;
        my $line = 0;
        my @out;

        dbg("DXCron::cread reading $fn\n") if isdbg('cron');
        open($fh, $fn) or confess("cron: can't open $fn $!");
        while (my $l = <$fh>) {
                $line++;
                chomp $l;
                next if $l =~ /^\s*#/ or $l =~ /^\s*$/;
                if (my ($ts) = $l =~/^\s*LOCALE\s*=\s*(UTC|LOCAL)/i) {
                        $ts = uc $ts;
                        if ($ts eq 'UTC') {
                                $use_localtime = 0;
                        } elsif ($ts eq 'LOCAL') {
                                $use_localtime = 1;
                        }
                        dbg("DXCron: LOCALE set to $ts") if isdbg('cron');
                }
                my ($min, $hour, $mday, $month, $wday, $cmd) = $l =~ /^\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.+)$/;
                next unless defined $min;
                my $ref = bless {};
                my $err = '';

                if (defined $min && defined $hour && defined $cmd) { # it isn't all of them, but should be enough to tell if this is a real line
                        $err .= parse($ref, 'min', $min, 0, 60);
                        $err .= parse($ref, 'hour', $hour, 0, 23);
                        $err .= parse($ref, 'mday', $mday, 1, 31);
                        $err .= parse($ref, 'month', $month, 1, 12, "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec");
                        $err .= parse($ref, 'wday', $wday, 0, 6, "sun", "mon", "tue", "wed", "thu", "fri", "sat");
                        if (!$err) {
                                $ref->{cmd} = $cmd;
                                push @out, $ref;
                                dbg("DXCron::cread: adding $l\n") if isdbg('cron');
                        } else {
                                $err =~ s/^, //;
                                LogDbg('cron', "DXCron::cread: error $err on line $line '$l'");
                        }
                } else {
                        LogDbg('cron', "DXCron::cread error on line $line '$l'");
                        my @s = ($min, $hour, $mday, $month, $wday, $cmd);
                        my $s = "line $line splits as " . join(', ', (map {defined $_ ? qq{$_} : q{'undef'}} @s));
                        LogDbg('cron', $s);
                }
        }
        close($fh);
        return @out;
}

sub parse
{
        my ($ref, $sort, $val, $low, $high, @names) = @_;
        my @req;

        # handle '*'
        if ($val eq '*') {
                $ref->{$sort} = undef;
                return '';
        }

        # handle */N (e.g. */5)
        if ($val =~ m{^\*/(\d+)$}) {
                my $step = $1;
                return ", $sort step must be > 0" if $step <= 0;
                for (my $i = $low; $i <= $high; $i += $step) {
                        push @req, $i;
                }
                $ref->{$sort} = \@req;
                return '';
        }

        # handle name-based values (like mon, tue, jan, etc)
        my %name_to_num;
        if (@names) {
                my $i = $low;
                for my $name (@names) {
                        $name_to_num{lc $name} = $i++;
                }
        }

        # handle comma-delimited values
        for my $part (split /,/, $val) {
                # handle ranges (e.g. 5-10)
                if ($part =~ /^(\d+)-(\d+)$/) {
                        my ($start, $end) = ($1, $2);
                        return ", $sort range out of bounds" if $start < $low || $end > $high;
                        push @req, $start..$end;
                }
                # handle names (e.g. mon, jan)
                elsif (@names && exists $name_to_num{lc $part}) {
                        push @req, $name_to_num{lc $part};
                }
                # handle single numbers
                elsif ($part =~ /^\d+$/) {
                        return ", $sort should be $low >= $part <= $high" if $part < $low || $part > $high;
                        push @req, $part;
                }
                else {
                        return ", invalid value '$part' for $sort";
                }
        }

        $ref->{$sort} = \@req;
        return '';
}

# process the cronjobs
sub process
{
        my $now = $main::systime;
        return if $now-$lasttime < 1;

        my ($sec, $min, $hour, $mday, $mon, $wday);
        if ($use_localtime) {
                ($sec, $min, $hour, $mday, $mon, $wday) = (localtime($now))[0,1,2,3,4,6];
        } else {
                ($sec, $min, $hour, $mday, $mon, $wday) = (gmtime($now))[0,1,2,3,4,6];
        }

        # are we at a minute boundary?
        if ($min != $lastmin) {

                # read in any changes if the modification time has changed
                init();

                $mon += 1;       # months otherwise go 0-11
                my $cron;
                foreach $cron (@crontab) {
                        if ((!$cron->{min} || grep $_ eq $min, @{$cron->{min}}) &&
                                (!$cron->{hour} || grep $_ eq $hour, @{$cron->{hour}}) &&
                                (!$cron->{mday} || grep $_ eq $mday, @{$cron->{mday}}) &&
                                (!$cron->{mon} || grep $_ eq $mon, @{$cron->{mon}}) &&
                                (!$cron->{wday} || grep $_ eq $wday, @{$cron->{wday}})  ){

                                if ($cron->{cmd}) {
                                        my $s = $use_localtime ? "LOCALTIME" : "UTC";
                                        dbg("cron: $s $min $hour $mday $mon $wday -> doing '$cron->{cmd}'") if isdbg('cron');
                                        eval $cron->{cmd};
                                        dbg("cron: cmd error $@") if $@ && isdbg('cron');
                                }
                        }
                }
        }

        # remember when we are now
        $lasttime = $now;
        $lastmin = $min;
}

#
# these are simple stub functions to make connecting easy in DXCron contexts
#

# is it locally connected?
sub connected
{
        my $call = uc shift;
        return DXChannel::get($call);
}

# is it remotely connected anywhere (with exact callsign)?
sub present
{
        my $call = uc shift;
        return Route::get($call);
}

# is it remotely connected anywhere (ignoring SSIDS)?
sub presentish
{
        my $call = uc shift;
        my $c = Route::get($call);
        unless ($c) {
                for (1..15) {
                        $c = Route::get("$call-$_");
                        last if $c;
                }
        }
        return $c;
}

# is it remotely connected anywhere (with exact callsign) and on node?
sub present_on
{
        my $call = uc shift;
        my $ncall = uc shift;
        my $node = Route::Node::get($ncall);
        return ($node) ? grep $call eq $_, $node->users : undef;
}

# is it remotely connected (ignoring SSIDS) and on node?
sub presentish_on
{
        my $call = uc shift;
        my $ncall = uc shift;
        my $node = Route::Node::get($ncall);
        my $present;
        if ($node) {
                $present = grep {/^$call/ } $node->users;
        }
        return $present;
}

# last time this thing was connected
sub last_connect
{
        my $call = uc shift;
        return $main::systime if DXChannel::get($call);
        my $user = DXUser::get($call);
        return $user ? $user->lastin : 0;
}

# disconnect a locally connected thing
sub disconnect
{
        my $call =  shift;
        run_cmd("disconnect $call");
}

# start a connect process off
sub start_connect
{
        my $call = shift;
        # connecting is now done in one place - Yeah!
        run_cmd("connect $call");
}

# spawn any old job off
sub spawn
{
        my $line = shift;
        my $t0 = [gettimeofday];

        dbg("DXCron::spawn: $line") if isdbg("cron");
        my $fc = DXSubprocess->new();
        $fc->run(
                         sub {
                                 my @res = `$line`;
#                                diffms("DXCron spawn 1", $line, $t0, scalar @res) if isdbg('chan');
                                 return @res
                         },
                         sub {
                                 my ($fc, $err, @res) = @_;
                                 if ($err) {
                                         my $s = "DXCron::spawn: error $err";
                                         dbg($s);
                                         return;
                                 }
                                 for (@res) {
                                         chomp;
                                         dbg("DXCron::spawn: $_") if isdbg("cron");
                                 }
                                 diffms("by DXCron::spawn", $line, $t0, scalar @res) if isdbg('progress');
                         }
                        );
}

sub spawn_cmd
{
        my $line = shift;
        my $t0 = [gettimeofday];

        dbg("DXCron::spawn_cmd run: $line") if isdbg('cron');
        my $fc = DXSubprocess->new();
        $fc->run(
                         sub {
                                 ++$main::me->{_nospawn};
                                 my @res = $main::me->run_cmd($line);
#                                diffms("DXCron spawn_cmd 1", $line, $t0, scalar @res) if isdbg('chan');
                                 return @res;
                         },
                         sub {
                                 my ($fc, $err, @res) = @_;
                                 --$main::me->{_nospawn};
                                 $main::me->{_nospawn} = 0 if exists $main::me->{_nospawn} && $main::me->{_nospawn} <= 0;
                                 if ($err) {
                                         my $s = "DXCron::spawn_cmd: error $err";
                                         dbg($s);
                                 }
                                 for (@res) {
                                         chomp;
                                         dbg("DXCron::spawn_cmd: $_") if isdbg("cron");
                                 }
                                 diffms("by DXCron::spawn_cmd", $line, $t0, scalar @res) if isdbg('progress');
                         }
                        );
}

# do an rcmd to another cluster from the crontab
sub rcmd
{
        my $call = uc shift;
        my $line = shift;

        # can we see it? Is it a node?
        my $noderef = Route::Node::get($call);
        return  unless $noderef && $noderef->version;

        # send it
        DXProt::addrcmd($main::me, $call, $line);
}

sub run_cmd
{
        my $line = shift;
        dbg("DXCron::run_cmd: $line") if isdbg('cron');
        my @in = $main::me->run_cmd($line);
        for (@in) {
                s/\s*$//;
                dbg("DXCron::cmd out: $_") if isdbg('cron');
        }
}

1;
__END__

