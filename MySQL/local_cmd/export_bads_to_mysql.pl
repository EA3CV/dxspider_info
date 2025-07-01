#!/usr/bin/perl

use strict;
use warnings;
use DBI;
use File::Spec;

# Variables globales de configuración
our ($mysql_db, $mysql_user, $mysql_pass, $mysql_host, $mysql_bads);

$mysql_db     ||= "dxspider";
$mysql_user   ||= "your_user";
$mysql_pass   ||= "your_pass";
$mysql_host   ||= "127.0.0.1";
$mysql_bads   ||= "bads";

my $data_dir = $ENV{DX_LOCAL_DATA} || '/root/volumenes/dxspider/nodo-2/local_data';
my @files = qw(baddx badnode badspotter);

# Conexión a la base de datos
my $dsn = "DBI:mysql:database=$mysql_db;host=$mysql_host";
my $dbh = DBI->connect($dsn, $mysql_user, $mysql_pass, {
    RaiseError => 1,
    PrintError => 0,
    mysql_enable_utf8mb4 => 1,
});

# Eliminar y recrear la tabla
$dbh->do("DROP TABLE IF EXISTS $mysql_bads");
$dbh->do(qq{
CREATE TABLE $mysql_bads (
    list_name   VARCHAR(32) NOT NULL,
    callsign    VARCHAR(32) NOT NULL,
    timestamp   BIGINT NOT NULL,
    PRIMARY KEY (list_name, callsign)
)
});

foreach my $file (@files) {
    my $path = File::Spec->catfile($data_dir, $file);
    open my $fh, '<', $path or do {
        warn "No se puede abrir $path: $!\n";
        next;
    };
    local $/;
    my $content = <$fh>;
    close $fh;

    # Extraer el hash de la estructura bless({...}, 'DXHash') sin punto y coma final
    if ($content =~ /bless\s*\(\s*(\{.*?\})\s*,\s*['\"]DXHash['\"]\s*\)/s) {
        $content = $1;
    } else {
        warn "No se pudo extraer estructura bless de $file\n";
        next;
    }

    my $data = eval $content;
    if ($@ || ref($data) ne 'HASH') {
        warn "Error al evaluar $file: $@\nContenido:\n$content\n";
        next;
    }

    my $sth = $dbh->prepare("REPLACE INTO $mysql_bads (list_name, callsign, timestamp) VALUES (?, ?, ?)");
    while (my ($call, $ts) = each %$data) {
        next if $call eq 'name';
        $sth->execute($file, $call, $ts);
    }

    my $count = scalar(keys %$data);
    $count-- if exists $data->{name};
    print "Migrado $file con $count registros.\n";
}

print "\nMigración completada.\n";
$dbh->disconnect;
