#
#  unset/badip - Remove IPs from the badip file / DB
#
#  Description:
#    Remove one or more IP addresses from the badip list used by DXCIDR.
#    Works with file backend (badip.local, badip.eu, badip.new, ...) and
#    MySQL/MariaDB backend (table badips).
#
#  Usage:
#    unset/badip [suffix] ip [ip2 ip3 ...]
#
#  Examples:
#    unset/badip 192.168.1.10
#    unset/badip new 2a00:6020:a799:eb00:2edd:d680:a76a:b077
#
#  Notes:
#    - If suffix is omitted:
#        * File backend: scans and removes from ALL badip.* files.
#        * DB backend: scans and removes from ALL list_type like 'badip.%'.
#    - If suffix is provided:
#        * Removes only from badip.<suffix> (e.g. badip.new)
#
#  Installation:
#    Place this script in: /spider/local_cmd/unset
#
#  Author:   Kin EA3CV <ea3cv@cronux.net>
#  Updates:  20260202 v1.1  fixed MariaDB schema (list_type) + remove from all lists/files
#

use strict;
use warnings;
use DXCIDR;
use DXVars;
use DBI;

my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd;
return (1, $self->msg('e5')) if $self->priv < 6;
return (1, q{Please install Net::CIDR::Lite or libnet-cidr-lite-perl to use this command}) unless $DXCIDR::active;

my @out;
my @in = split /\s+/, ($line // '');

# If first token looks like a suffix, use it; otherwise scan all.
# We only treat it as suffix if there is at least one more argument after it.
my $suffix;
if (@in > 1 && defined $in[0] && $in[0] =~ /^[_\w\d]+$/) {
    $suffix = shift @in;   # explicit suffix requested by user
}

return (1, "unset/badip: need [suffix] IP(s)") unless @in;

# Keep only valid IPs; normalize lowercase for safety (IPv6)
my %to_remove = map { lc($_) => 1 } grep { is_ipaddr($_) } @in;
return (1, "unset/badip: no valid IPs provided") unless %to_remove;

my %removed_in;     # where => { ip => 1, ... }
my @errors;

# Backend detect
my $use_mysql = defined $main::db_backend
             && ($main::db_backend eq 'mysql' || $main::db_backend eq 'mariadb');

if ($use_mysql) {

    # DSN (DBD::mysql works for MariaDB too in most installs)
    my $dbh = DBI->connect(
        "DBI:mysql:database=$main::mysql_db;host=$main::mysql_host",
        $main::mysql_user,
        $main::mysql_pass,
        { RaiseError => 1, AutoCommit => 1, mysql_enable_utf8mb4 => 1 }
    );

    my $table = $main::mysql_badips || 'badips';

    # Your schema: (ip, ts, list_type)
    # We'll delete by ip + list_type (e.g. badip.new)
    my @list_types;

    if (defined $suffix) {
        @list_types = ("badip.$suffix");
    } else {
        # Scan all badip.* list types present
        my $sth_s = $dbh->prepare("SELECT DISTINCT list_type FROM $table WHERE list_type LIKE 'badip.%'");
        $sth_s->execute();
        while (my ($lt) = $sth_s->fetchrow_array) {
            push @list_types, $lt if defined $lt && length $lt;
        }
    }

    # If DB has no badip.* list types, fall back to the historical default
    @list_types = ('badip.local') unless @list_types;

    my $sth = $dbh->prepare("DELETE FROM $table WHERE ip = ? AND list_type = ?");

    for my $lt (@list_types) {
        for my $ip (keys %to_remove) {
            # IMPORTANT: DB stores IP as plain string (no /128 or /32)
            my $count = $sth->execute($ip, $lt);

            # Robust check: only count if rows were affected
            if (defined($count) && $count > 0) {
                $removed_in{$lt}{ $ip } = 1;
            }
        }
    }

    $dbh->disconnect;

} else {
    # File backend
    my $base = DXCIDR::_fn();  # e.g. /spider/data/badip
    my $dir  = $base;
    $dir =~ s{/[^/]+$}{};      # directory containing badip.*

    my @files;
    if (defined $suffix) {
        push @files, "$base.$suffix";
    } else {
        # Scan all badip.* files in the directory
        my $prefix = $base; $prefix =~ s{^.*/}{};
        if (opendir my $dh, $dir) {
            @files = map { "$dir/$_" }
                     grep { /^\Q$prefix\E\./ && -f "$dir/$_" }
                     readdir $dh;
            closedir $dh;
        } else {
            return (1, "unset/badip: cannot open directory $dir: $!");
        }
    }

    return (1, "unset/badip: no badip.* files found") unless @files;

    FILE:
    for my $fn (@files) {

        unless (-e $fn) {
            push @errors, "unset/badip: file $fn does not exist.";
            next FILE;
        }

        my @lines;
        if (open my $fh, '<', $fn) {
            @lines = <$fh>;
            close $fh;
        } else {
            push @errors, "unset/badip: cannot read $fn: $!";
            next FILE;
        }

        my @kept;
        my $changed = 0;

        LINE:
        for my $orig (@lines) {
            my $line = $orig;
            chomp $line;

            # Strip comments and trim
            $line =~ s/#.*$//;
            $line =~ s/^\s+|\s+$//g;

            # Keep empty/comment-only lines as-is
            if ($line eq '') {
                push @kept, $orig;
                next LINE;
            }

            # Only match against the first token (handles "ip comment" / "ip tag")
            my ($key) = split /\s+/, $line, 2;
            $key = lc($key // '');

            # If key matches the ip exactly, remove it
            if (exists $to_remove{$key}) {
                $removed_in{$fn}{ $key } = 1;
                $changed = 1;
                next LINE;
            }

            push @kept, $orig;
        }

        # Rewrite file only if changed
        if ($changed) {
            if (open my $fh, '>', $fn) {
                print $fh $_ for @kept;  # preserve original newlines
                close $fh;
            } else {
                push @errors, "unset/badip: cannot write to $fn: $!";
            }
        }
    }
}

# Reload the updated list
DXCIDR::reload();

# Output summary
if (%removed_in) {
    for my $where (sort keys %removed_in) {
        my @ips = sort keys %{ $removed_in{$where} };
        push @out, "unset/badip: removed " . scalar(@ips) . " IP(s) from $where: @ips";
    }
} else {
    my $scope = defined $suffix ? "badip.$suffix" : "all badip.*";
    push @out, "unset/badip: no matching IPs found in $scope";
}

push @out, @errors if @errors;

return (1, @out);
