#!/usr/bin/perl

#
# Compression of the previous day's debug files
#
# To be copied to spider/local_cmd
# This can be included in DXSpider's crontab as something like this:
# 10 0 * * * spawn("/spider/local_cmd/compression.pl")
#
# Kin EA3CV
#
# 20240728 v0.2
#

use strict;
use warnings;
use Time::Piece;
use POSIX qw(strftime);

$ENV{TZ} = "UTC";

my $today = strftime("%Y-%j", gmtime);
my ($current_year, $current_day) = split('-', $today);

my ($y, $d);

if ($current_day == 1) {
    $y = $current_year - 1;
    $d = 365;
    # Adjust for leap year
    $d = 366 if (Time::Piece->strptime("$y-12-31", "%Y-%m-%d")->is_leap_year);
} else {
    $y = $current_year;
    $d = $current_day - 1;
    $d = sprintf("%03d", $d);
}

my $file = "/spider/local_data/debug/$y/$d.dat";

if (-e $file) {
    my @compress = ('gzip', '-9', $file);
    system(@compress) == 0 or warn "Compression failed: $!";
} else {
    warn "File $file does not exist.";
}
