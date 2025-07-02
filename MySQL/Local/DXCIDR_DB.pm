package DXCIDR_DB;

use strict;
use warnings;
use 5.16.1;

use DBI;
use DXVars;
use DXUtil;
use DXDebug;
use Net::CIDR::Lite;

my $dbh;
my $table = $main::mysql_badips || 'badips';

sub new {
    return bless {}, __PACKAGE__;
}

sub _connect {
    return $dbh if $dbh;
    $dbh = DBI->connect("DBI:mysql:database=$main::mysql_db;host=$main::mysql_host",
                       $main::mysql_user,
                       $main::mysql_pass,
                       { RaiseError => 1, AutoCommit => 1, mysql_enable_utf8 => 1 })
        or die "Could not connect to database: $DBI::errstr";
    return $dbh;
}

sub _normalize_ip {
    my ($ip) = @_;
    return unless is_ipaddr($ip);
    return $ip =~ /:/ ? "$ip/128" : "$ip/32";
}

sub add_ips {
    my ($suffix, @ips) = @_;
    my $dbh = _connect();
    my $sth = $dbh->prepare("INSERT IGNORE INTO $table (ip, version, suffix) VALUES (?, ?, ?)");
    my $count = 0;
    my $final_suffix = (defined $suffix && $suffix ne '') ? $suffix : 'local';
    for my $ip (@ips) {
        next unless is_ipaddr($ip);
        my $cidr = _normalize_ip($ip);
        my $version = ($ip =~ /:/) ? 6 : 4;
        $sth->execute($cidr, $version, $final_suffix) and $count++;
    }
    return $count;
}

sub append_ips {
    return add_ips(@_);
}

sub find_ip {
    my ($ip) = @_;
    my $cidr = _normalize_ip($ip);
    return 0 unless $cidr;
    my $dbh = _connect();
    my $sth = $dbh->prepare("SELECT COUNT(*) FROM $table WHERE ip = ?");
    $sth->execute($cidr);
    my ($count) = $sth->fetchrow_array;
    return $count ? 1 : 0;
}

sub list_ips {
    my $dbh = _connect();
    my $sth = $dbh->prepare("SELECT ip FROM $table");
    $sth->execute();
    my @ips;
    while (my ($ip) = $sth->fetchrow_array) {
        push @ips, $ip;
    }
    return @ips;
}

sub load_ips {
    my ($suffix) = @_;
    my $dbh = _connect();
    my $sth = $dbh->prepare("SELECT ip FROM $table WHERE suffix = ?");
    $sth->execute($suffix);
    my @ips;
    while (my ($ip) = $sth->fetchrow_array) {
        push @ips, $ip;
    }
    return scalar @ips;
}

sub reload {
    return 1;  # no-op para SQL
}

1;
