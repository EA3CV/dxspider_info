#!/usr/bin/perl

#
# Search debug by string(s) and a human time range.
#
# AND and OR are used to define the filtering applied to all strings.
# The format of the date is YYYYYMMDD-HH:MM:SS
# Example: ./search.pl 20250323-17:05:00 20250323-17:25:00 ../local_data/debug/2025/085.dat AND "I EA0XXX-2 PC61" JN68px
#
# Requires: cpanm Term::ExtendedColor
#
# Kin EA3CV ea3cv@cronux.net
#
# 20250326 v0.2
#

use strict;
use warnings;
use Time::Local;
use Term::ExtendedColor qw(:all);

if (@ARGV < 5) {
    die "Uso: $0 <start_date> <end_date> <file> <AND|OR> <string_to_search1> <string_to_search2> ...\n";
}

my ($fecha_inicio, $fecha_fin, $archivo, $operador, @cadenas_a_buscar) = @ARGV;

my $regex;
if ($operador eq "AND") {
    $regex = join('.*', map { quotemeta($_) } @cadenas_a_buscar);
} else {
    $regex = join('|', map { quotemeta($_) } @cadenas_a_buscar);
}

my @colores = ('blue', 'red', 'yellow', 'cyan', 'green');
my %color_codes = (
    blue   => 27,
    red    => 196,
    yellow => 226,
    cyan   => 51,
    green  => 46,
);

my $epoch_inicio = parse_fecha($fecha_inicio);
my $epoch_fin = parse_fecha($fecha_fin);

open my $fh, '<', $archivo or die "Unable to open the file '$archivo': $!\n";

while (my $linea = <$fh>) {
    
    my $match = 0;
    if ($operador eq "AND") {
        $match = 1;
        foreach my $cadena (@cadenas_a_buscar) {
            if ($linea !~ /\Q$cadena\E/i) {
                $match = 0;
                last;
            }
        }
    } else {
        $match = ($linea =~ /$regex/i);
    }
    if ($match) {

        my $epoch = (split ' ', $linea)[0];
        $epoch =~ s/\D//g;

        if ($epoch >= $epoch_inicio && $epoch <= $epoch_fin) {
            my $fecha_formateada = epoch_a_fecha($epoch);
            $linea =~ s/^\d+/$fecha_formateada/;

            for (my $i = 0; $i < @cadenas_a_buscar; $i++) {
                my $color = $colores[$i % @colores];
                my $fg = fg($color_codes{$color});
                my $reset = clear();
                $linea =~ s/($cadenas_a_buscar[$i])/$fg . $1 . $reset/ige;
            }

            print $linea;
        }
    }
}

sub parse_fecha {
    my ($fecha) = @_;
    my ($y, $m, $d, $h, $min, $s) = $fecha =~ /(\d{4})(\d{2})(\d{2})-(\d{2}):(\d{2}):(\d{2})/;
    return timelocal($s, $min, $h, $d, $m-1, $y-1900);
}

sub epoch_a_fecha {
    my ($epoch) = @_;
    my @time = localtime($epoch);
    return sprintf "%04d%02d%02d-%02d:%02d:%02d",
        $time[5] + 1900, $time[4] + 1, $time[3], $time[2], $time[1], $time[0];
}
