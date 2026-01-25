#
# clear/dbspots
#
# Delete DX spots from SQL table "spot" older than a given date start (YYYYMMDD).
# Keeps all newer records.
#
# Usage:
#   clear/dbspots YYYYMMDD
#
# Notes:
# - Requires SQL enabled ($main::dbh must exist)
# - Deletes in batches to avoid long locks (LIMIT 10000)
# - Cutoff is start-of-day UTC for the given date (00:00:00Z)
#
# Place this file as:
#   /spider/local_cmd/clear/dbspots.pl
#   from console:
#   load/cmd
#
# Kin EA3CV <ea3cv@cronux.net>
#
# 20260125 v1.0
#

use strict;
use warnings;

use Time::Local qw(timegm);

my ($self, $line) = @_;
my @f = split /\s+/, ($line // '');
my @out;

# Privilege check (sysop/admin). Adjust if you want priv>=8 instead.
if (($self->{priv} // 0) < 9) {
    push @out, "Sorry, you need sysop privilege (9) to run clear/dbspots";
    return (1, @out);
}

# Must have SQL enabled
unless ($main::dbh && ref $main::dbh && $main::dbh->{dbh}) {
    push @out, "SQL is not active (no database handle). Check \$dsn/\$dbuser/\$dbpass and restart cluster.";
    return (1, @out);
}

my $arg = $f[0] // '';
$arg =~ s/\D//g;

unless ($arg =~ /^\d{8}$/) {
    push @out, "Usage: clear/dbspots YYYYMMDD  (example: clear/dbspots 20260101)";
    return (1, @out);
}

my ($yyyy, $mm, $dd) = ($arg =~ /^(\d{4})(\d{2})(\d{2})$/);

# Validate date by round-trip via gmtime
my $cutoff_epoch;
eval {
    $cutoff_epoch = timegm(0, 0, 0, $dd, $mm - 1, $yyyy);  # 00:00:00 UTC
};
if ($@ || !defined $cutoff_epoch) {
    push @out, "Invalid date '$arg' (cannot convert to epoch)";
    return (1, @out);
}

my @chk = gmtime($cutoff_epoch);
my $yyyy2 = $chk[5] + 1900;
my $mm2   = $chk[4] + 1;
my $dd2   = $chk[3];

if ($yyyy2 != $yyyy || $mm2 != $mm || $dd2 != $dd) {
    push @out, "Invalid date '$arg' (date does not exist)";
    return (1, @out);
}

my $dbh = $main::dbh->{dbh};

# How many rows would be deleted?
my $to_delete = 0;
eval {
    my $sth = $dbh->prepare("SELECT COUNT(*) FROM spot WHERE time < ?");
    $sth->execute($cutoff_epoch);
    ($to_delete) = $sth->fetchrow_array;
    $sth->finish;
};
if ($@) {
    push @out, "DB error (count): $@";
    return (1, @out);
}

if (!$to_delete) {
    push @out, sprintf("No rows to delete. Cutoff: %04d-%02d-%02d 00:00:00Z (epoch %d)", $yyyy, $mm, $dd, $cutoff_epoch);
    return (1, @out);
}

push @out, sprintf("Deleting %d spot rows with time < %04d-%02d-%02d 00:00:00Z (epoch %d) ...",
                   $to_delete, $yyyy, $mm, $dd, $cutoff_epoch);

# Delete in batches to avoid long locks / huge undo logs
my $batch = 10_000;
my $deleted_total = 0;
my $loops = 0;

eval {
    while (1) {
        my $rows = $dbh->do("DELETE FROM spot WHERE time < " . $dbh->quote($cutoff_epoch) . " LIMIT $batch");
        $rows = 0 unless defined $rows && $rows > 0;
        $deleted_total += $rows;
        $loops++;

        last if $rows < $batch;  # finished
        last if $loops > 1_000_000; # hard safety brake
    }
};
if ($@) {
    push @out, "DB error (delete): $@";
    push @out, "Deleted so far: $deleted_total (may be partial).";
    return (1, @out);
}

push @out, "Done. Deleted: $deleted_total.";

# Optional: advise on optimize (not auto-run; can be heavy)
push @out, "Note: indexes are not harmed. After large purges you MAY run: OPTIMIZE TABLE spot; (off-peak)";

return (1, @out);

