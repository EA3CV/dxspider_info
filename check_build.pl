#!/usr/bin/perl

#
# Check if there is a new build.
# Setting 'Y' will backup to /home/sysop/backup
# Download and install.
#
# Only for the Mojo branch
# and in the Spanish and English languages.
#
# Include the following line in the crontab:
# 0 4 * * 1,2,3,4,5 run_cmd("check_build <Y/N>")
#
# You need the following package:
# apt install libfile-copy-recursive-perl  or
# cpan install File::Copy::Recursive
#
# Kin EA3CV, ea3cv@cronux.net
#
# 20230208 v1.6
#

use 5.10.1;
use DXDebug;
use File::Copy::Recursive;
use strict;
use warnings;

my $self = shift;
my $bckup = shift;

return (1) unless $self->priv >= 9;

my @state = `git remote show origin`;
system('cd /spider;');

my $res;
my @out;

@state = map { s/\s+|\s+$/ /g; $_ } @state;

#push @out, @state;

if ((/mojo/i ~~ @state) && (/mojo pushes to mojo \(local out of date\)|mojo publica a mojo \(desactualizado local\)/i ~~ @state)) {
        $res = "There is a new build";
        dbg('DXCron::spawn: $res') if isdbg('cron');
        push @out, $res;
        my $load = "*$main::mycall*   🆕  *UPDATE* New build";
        is_tg($load);

        backup() if $bckup =~ /Y/i;

        system('git reset --hard');
        system('git pull');
        DXCron::run_cmd('shut');

} elsif ((/mojo/i ~~ @state) && (/mojo pushes to mojo \(up to date\)|mojo publica a mojo \(actualizado\)/i ~~ @state)) {
        $res = "There is no new build";
        push @out, $res;
        dbg('DXCron::spawn: $res') if isdbg('cron');
}


sub backup
{
        my $from_dir = "/home/sysop/spider";
        my $to_dir = "/home/sysop/spider.backup";

        if ( !-d $to_dir ) {
                system('mkdir', $to_dir);
        }

        my $load = "*$main::mycall*   💾  *Backup Starts*";
        is_tg($load);

        File::Copy::Recursive::rcopy_glob($from_dir, $to_dir);

        $load = "*$main::mycall*   🆗  *Backup Completed*";
        is_tg($load);

}

sub is_tg
{
        my $msg = shift;

        if (defined &Local::telegram) {
                my $r;
                eval { $r = Local::telegram($msg); };
                return if $r;
        }
}

return (1, @out)
