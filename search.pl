#!/usr/bin/perl

#
# Search debug by string(s) and a human time range.
#
# AND and OR are used to define the filtering applied to all strings.
# The format of the date is YYYYYMMDD-HHMMSS
# Example: ./search.pl 20250323-170500 20250323-172500 debug/2025/085.dat AND "I EA0XXX-2 PC61" JN68px
#
# May need to be installed: cpan Term::ANSIColor
#
# Kin EA3CV ea3cv@cronux.net
#
# 20250326 v0.1
#

use strict;
use warnings;
use Time::Local;
use Term::ANSIColor;

if (@ARGV < 5) {
    die "Uso: $0 <start_date> <end_date> <file> <AND|OR> <string_to_search1> <string_to_search2> <string_to_search2>. ...\n";
}

my ($fecha_inicio, $fecha_fin, $archivo, $operador, @cadenas_a_buscar) = @ARGV;

my $regex;
if ($operador eq "AND") {
    $regex = join('.*', map { quotemeta($_) } @cadenas_a_buscar);
} else {
    $regex = join('|', map { quotemeta($_) } @cadenas_a_buscar);
}

my @colores = ('blue', 'red', 'yellow', 'cyan', 'green');

my $epoch_inicio = parse_fecha($fecha_inicio);
my $epoch_fin = parse_fecha($fecha_fin);

open my $fh, '<', $archivo or die "Unable to open the file '$archivo': $!\n";

while (my $linea = <$fh>) {
    if ($linea =~ /$regex/) {
        my $epoch = (split ' ', $linea)[0];
        $epoch =~ s/\D//g;

        if ($epoch >= $epoch_inicio && $epoch <= $epoch_fin) {
            my $fecha_formateada = epoch_a_fecha($epoch);
            $linea =~ s/^\d+/$fecha_formateada/;

            for (my $i = 0; $i < @cadenas_a_buscar; $i++) {
                my $color = $colores[$i % @colores];
                $linea =~ s/($cadenas_a_buscar[$i])/colored($1, $color)/ge;
            }

            print $linea;
        }
    }
}

sub parse_fecha {
    my ($fecha) = @_;
    my ($y, $m, $d, $h, $min, $s) = $fecha =~ /(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/;
    return timelocal($s, $min, $h, $d, $m-1, $y-1900);
}

sub epoch_a_fecha {
    my ($epoch) = @_;
    my @time = localtime($epoch);
    my $fecha = sprintf "%04d%02d%02d-%02d%02d%02d",
        $time[5] + 1900, $time[4] + 1, $time[3], $time[2], $time[1], $time[0];
    return $fecha;
}
