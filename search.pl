#!/usr/bin/perl

#
# Search debug by string(s) and a human time range.
#
# En modo OR usa `grep` externo para acelerar la búsqueda y aplica color amarillo.
# En modo AND aplica colores múltiples a cada cadena.
# El formato de fecha es YYYYMMDD-HH:MM:SS
#
# Kin EA3CV ea3cv@cronux.net
#
# 20250326 v0.5
#

use strict;
use warnings;
use Time::Local;
use Term::ExtendedColor qw(:all);

if (@ARGV < 5) {
    die "Uso: $0 <start_date> <end_date> <file> <AND|OR> <cadena1> <cadena2> ...\n";
}

my ($fecha_inicio, $fecha_fin, $archivo, $operador, @cadenas_a_buscar) = @ARGV;

my $epoch_inicio = parse_fecha($fecha_inicio);
my $epoch_fin    = parse_fecha($fecha_fin);

my @lineas;

if (uc($operador) eq "OR") {
    my $pattern = join('|', map { quotemeta($_) } @cadenas_a_buscar);
    my $cmd = qq{grep -i -E "$pattern" "$archivo"};

    open(my $fh, "$cmd |") or die "No se pudo ejecutar grep: $!";
    @lineas = <$fh>;
    close($fh);
} else {
    open(my $fh, '<', $archivo) or die "No se puede abrir el archivo '$archivo': $!\n";
    while (my $linea = <$fh>) {
        my $match = 1;
        foreach my $cadena (@cadenas_a_buscar) {
            if ($linea !~ /\Q$cadena\E/i) {
                $match = 0;
                last;
            }
        }
        push @lineas, $linea if $match;
    }
    close($fh);
}

my @colores = ('blue', 'red', 'yellow', 'cyan', 'green');
my %color_codes = (
    blue   => 27,
    red    => 196,
    yellow => 226,
    cyan   => 51,
    green  => 46,
);

foreach my $linea (@lineas) {
    my ($epoch) = $linea =~ /(\d{10})/;
    next unless defined $epoch;

    if ($epoch >= $epoch_inicio && $epoch <= $epoch_fin) {
        my $fecha_formateada = epoch_a_fecha($epoch);
        $linea =~ s/^\d+/$fecha_formateada/;

        if (uc($operador) eq "AND") {
            for (my $i = 0; $i < @cadenas_a_buscar; $i++) {
                my $color = $colores[$i % @colores];
                my $fg = fg($color_codes{$color});
                my $reset = clear();
                my $cadena = $cadenas_a_buscar[$i];
                $linea =~ s/($cadena)/$fg . $1 . $reset/ige;
            }
        } elsif (uc($operador) eq "OR") {
            my $fg = fg(226);  # amarillo
            my $reset = clear();
            foreach my $cadena (@cadenas_a_buscar) {
                $linea =~ s/($cadena)/$fg . $1 . $reset/ige;
            }
        }

        print $linea;
    }
}

sub parse_fecha {
    my ($fecha) = @_;
    my ($y, $m, $d, $h, $min, $s) = $fecha =~ /(\d{4})(\d{2})(\d{2})-(\d{2}):(\d{2}):(\d{2})/;
    die "Formato de fecha incorrecto. Usa: YYYYMMDD-HH:MM:SS\n" unless defined $y;
    return timelocal($s, $min, $h, $d, $m-1, $y-1900);
}

sub epoch_a_fecha {
    my ($epoch) = @_;
    my @t = localtime($epoch);
    return sprintf "%04d%02d%02d-%02d:%02d:%02d",
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}
