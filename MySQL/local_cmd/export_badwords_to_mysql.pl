#!/usr/bin/perl
use strict;
use warnings;
use DBI;
use IO::File;
use File::Spec;

# Variables globales de configuración
our ($mysql_db, $mysql_user, $mysql_pass, $mysql_host, $mysql_bads);

$mysql_db     ||= "dxspider";
$mysql_user   ||= "your_user";
$mysql_pass   ||= "your_pass";
$mysql_host   ||= "127.0.0.1";
my $tabla = 'badwords';

# Conexión MySQL
my $dbh = DBI->connect(
    "DBI:mysql:database=$main::mysql_db;host=$main::mysql_host",
    $main::mysql_user,
    $main::mysql_pass,
    { RaiseError => 1, AutoCommit => 1, mysql_enable_utf8mb4 => 1 }
) or die "Error al conectar con MySQL: $DBI::errstr";

# Crear tabla si no existe
$dbh->do(qq{
    CREATE TABLE IF NOT EXISTS $tabla (
        word VARCHAR(64) NOT NULL PRIMARY KEY
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
});

# Vaciar la tabla
$dbh->do("DELETE FROM $tabla");

# Limpieza de palabra
sub _cleanword {
    my $w = uc shift;
    $w =~ tr/01/OI/;
    my $last = '';
    my @w;
    for (split //, $w) {
        next if $last eq $_;
        $last = $_;
        push @w, $_;
    }
    return join('', @w);
}

# Leer palabras de ficheros
my %palabras;
my $base_dir = '/root/volumenes/dxspider/nodo-2/local_data';

my $newfile = File::Spec->catfile($base_dir, 'badword.new');
if (-e $newfile) {
    print "[INFO] Usando badword.new\n";
    my $fh = IO::File->new($newfile);
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;
        my $w = _cleanword($line);
        $palabras{$w} = 1 if $w;
    }
    $fh->close;
} else {
    my $bw_file = File::Spec->catfile($base_dir, 'badword');
    if (-e $bw_file) {
        print "[INFO] Usando badword (estilo antiguo)\n";
        my $fh = IO::File->new($bw_file);
        while (my $line = <$fh>) {
            chomp $line;
            next if $line =~ /^\s*#/;
            if ($line =~ /^(\w+)\s+=>\s+\d+,/) {
                my $w = _cleanword($1);
                $palabras{$w} = 1 if $w;
            }
        }
        $fh->close;
    }

    my $regex_file = File::Spec->catfile($base_dir, 'badw_regex');
    if (-e $regex_file) {
        print "[INFO] Usando badw_regex\n";
        my $fh = IO::File->new($regex_file);
        while (my $line = <$fh>) {
            chomp $line;
            next if $line =~ /^\s*#/;
            for my $w (split /\s+/, uc $line) {
                $w = _cleanword($w);
                $palabras{$w} = 1 if $w;
            }
        }
        $fh->close;
    }
}

# Insertar en la tabla
my $sth = $dbh->prepare("INSERT INTO $tabla (word) VALUES (?)");
my $count = 0;
for my $w (sort keys %palabras) {
    $sth->execute($w);
    $count++;
}

print "[OK] $count palabras insertadas en la tabla '$tabla'\n";

$dbh->disconnect;
