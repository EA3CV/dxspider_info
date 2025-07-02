#!/usr/bin/env perl

use strict;
use warnings;
use 5.16.1;

use lib '/spider/local';
use lib '/spider/perl';

use DBI;
use IO::File;
use DXVars;
use DXUtil;

my $table = $main::mysql_badips // 'badips';
my $dummy = $main::mysql_badips;  # evitar warning 'used only once'

my $dbh = DBI->connect("DBI:mysql:database=$main::mysql_db;host=$main::mysql_host",
                      $main::mysql_user,
                      $main::mysql_pass,
                      { RaiseError => 1, AutoCommit => 1, mysql_enable_utf8 => 1 })
  or die "Cannot connect to database: $DBI::errstr";

# Crear o recrear tabla
$dbh->do("DROP TABLE IF EXISTS $table");
$dbh->do(<<"SQL");
CREATE TABLE $table (
  id INT AUTO_INCREMENT PRIMARY KEY,
  ip VARCHAR(64) NOT NULL,
  version TINYINT NOT NULL,
  suffix VARCHAR(16) DEFAULT '',
  UNIQUE KEY ip_suffix (ip, suffix)
)
SQL

# Directorio fijo para los ficheros badip.*
my $dir = "/spider/local_data";
opendir(my $dh, $dir) or die "Cannot open directory $dir: $!";

my $sth = $dbh->prepare("INSERT IGNORE INTO $table (ip, version, suffix) VALUES (?, ?, ?)");

while (my $file = readdir $dh) {
    next unless $file =~ /^badip\.(\w+)$/;
    my $suffix = $1;
    my $path = "$dir/$file";
    my $fh = IO::File->new($path, 'r') or die "Cannot open $path: $!";

    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/ || $line !~ /[\.:]/;
        $line =~ s/\s+//g;
        next unless $line;
        next unless is_ipaddr($line);

        my $version = $line =~ /:/ ? 6 : 4;
        my $cidr = $version == 6 ? "$line/128" : "$line/32";
        $sth->execute($cidr, $version, $suffix);
    }
    $fh->close;
    print "Migrado: $file\n";
}

closedir $dh;
print "\nMigración completada con éxito.\n";
