#!/usr/bin/perl

#
# Updating the $main::localhost_alias_ipv4 and @main::localhost_names var
#
# Copy to /spider/local_cmd/update_ip.pl
#
# Configure crontab:
# 00,10,20,30,40,50 * * * * run_cmd("update_ip")
#
# Notes:
#
# Need: apt install libpath-tiny-perl or
# Module: cpanm install Path::Tiny
#
# Kin EA3CV ea3cv@cronux.net
#
# 20250322 v1.2
#

use 5.10.1;
use Path::Tiny qw(path);
use strict;
use warnings;

my $ip = `curl -s ifconfig.me`;
my $ips = `hostname -I`;          # -i para Docker, -I para el resto
chomp($ip);  # Eliminar salto de línea de la IP pública

my $var1 = 'set/var $main::localhost_alias_ipv4 =';
$ip = "'$ip'";
my $find1 = 'localhost_alias_ipv4';
startup($var1, $ip, $find1);

my @out;

my $msg1 = $var1 . $ip;

my $var2 = 'set/var @main::localhost_names qw( 127.0.0.1 ::1';
# Eliminar espacios y saltos de línea finales en $ips antes de concatenar
$ips =~ s/\s+$//;  # Eliminar espacios extra o salto de línea al final de $ips
$ips = " $ips)";    # Asegurarse de que el paréntesis esté en la misma línea
my $find2 = 'localhost_names';
startup($var2, $ips, $find2);

my $msg2 = $var2 . $ips;
cmd_import($msg1, $msg2);

# Subrutina para importar el archivo y escribir en el directorio de importación
sub cmd_import {
    my @out;
    my $msg1 = shift;
    my $msg2 = shift;

    my $dir = "/spider/cmd_import";
    # Crear el directorio si no existe
    if ( !-d $dir ) {
        system('mkdir', $dir);
    }

    my $file = $dir . "/" . 'update_ip';

    open (FH, '>', $file) or die "No se pudo abrir el archivo $file: $!";
    say FH $msg1;
    say FH $msg2;
    close (FH);

    # Añadir a la lista de salida
    push @out, " Updated Public and Local IPs.";
    push @out, " ";
}

# Subrutina de configuración de inicio
sub startup {
    my $var = shift;
    my $arg = shift;
    my $find = shift;

    my $filename = '/spider/scripts/startup';
    my @content = path($filename)->lines_utf8;

    my $e = 0;
    # Recorrer el contenido del archivo y realizar cambios
    foreach my $row (@content) {
        if ($row =~ m/$find/) {
            $row =~ s/.*$find.*/$var $arg/g;
            path($filename)->spew_utf8(@content);  # Guardar los cambios en el archivo
            $e = 1;
        }
    }

    # Si no se encontró, añadir al final del archivo
    if ($e == 0) {
        my $data = <<EOF;
#
$var $arg
EOF
        path($filename)->append_utf8($data);
    }
}

# Devolver el resultado
return (1, @out);
