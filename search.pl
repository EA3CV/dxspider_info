#!/usr/bin/perl

#
# Search debug by string(s) and a human time range.
#
# Descubre cómo funciona, hihihi
#
# Kin
# 20250329 v1.0
#

use strict;
use warnings;
use Getopt::Long;
use Time::Local;
use POSIX qw(strftime);
use Term::ANSIColor;

my @colors = ('blue', 'red', 'yellow', 'cyan', 'green');

my ($file, $epoch_mode, $human_mode, $start, $end, $help);
my $filter_expr;

GetOptions(
    'f=s'        => \$file,
    'l'          => \$epoch_mode,
    'h'          => \$human_mode,
    's=s'        => \$start,
    'e=s'        => \$end,
    'filter=s'   => \$filter_expr,
    'help|?'     => \$help,
) or die "Error in arguments. Use --help for usage info.\n";

if ($help) {
    print_help();
    exit 0;
}

unless ($file) {
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
    my $day_of_year = strftime("%j", localtime);
    $file = "$day_of_year.dat";
    print STDERR "ℹ️  No se indicó -f. Se usará automáticamente el fichero: $file\n";
}

my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
$year += 1900;
$mon  += 1;

sub parse_time {
    my $t = shift;
    if ($t =~ /^(\d{8})-(\d{6})$/) {
        my ($date, $time) = ($1, $2);
        return timelocal(substr($time,4,2), substr($time,2,2), substr($time,0,2),
                         substr($date,6,2), substr($date,4,2)-1, substr($date,0,4)-1900);
    } elsif ($t =~ /^(\d{6})$/) {
        return timelocal(substr($t,4,2), substr($t,2,2), substr($t,0,2),
                         $mday, $mon-1, $year-1900);
    } elsif ($t =~ /^\d+$/) {
        return $t;
    } else {
        die "Invalid time format: $t\n";
    }
}

my $start_epoch;
if (defined $start) {
    $start_epoch = parse_time($start);
} elsif (defined $end) {
    $start_epoch = 0;
} elsif ($epoch_mode || $human_mode) {
    $start_epoch = timelocal(0,0,0,$mday,$mon-1,$year-1900);
} else {
    $start_epoch = 0;
}

my $end_epoch = defined($end) ? parse_time($end) : time();

if ($filter_expr && $filter_expr =~ /"[^"]*[\|\&][^"]*"/) {
    print STDERR "\n⚠️  Warning: You used '|' or '&' inside double quotes in the filter:\n";
    print STDERR "    '$filter_expr'\n";
    print STDERR "    This will be treated as a literal string, NOT a logical condition.\n";
    my $suggested = $filter_expr =~ s/"//gr;
    print STDERR "    Did you mean: $suggested ? [Y/n]: ";
    my $answer = <STDIN>;
    chomp $answer;
    if (lc($answer) eq 'y' || $answer eq '') {
        $filter_expr = $suggested;
        print STDERR "✅ Filter automatically corrected to: $filter_expr\n";
    } else {
        print STDERR "🔸 Using original filter as-is.\n";
    }
}

sub expr_to_perl {
    my $expr = shift;
    my @tokens;
    my $buffer = '';
    my $in_quotes = 0;

    for (my $i = 0; $i < length($expr); $i++) {
        my $c = substr($expr, $i, 1);
        if ($c eq '"') {
            $in_quotes = !$in_quotes;
            next;
        }
        if ($in_quotes) {
            $buffer .= $c;
        } else {
            if ($c =~ /\s/) {
                next;
            } elsif ($c eq '&' || $c eq '|') {
                push @tokens, $buffer if $buffer ne '';
                push @tokens, $c;
                $buffer = '';
            } elsif ($c eq '(' || $c eq ')') {
                push @tokens, $buffer if $buffer ne '';
                push @tokens, $c;
                $buffer = '';
            } else {
                $buffer .= $c;
            }
        }
    }
    push @tokens, $buffer if $buffer ne '';

    my @perl_expr;
    foreach my $t (@tokens) {
        if ($t eq '&') {
            push @perl_expr, '&&';
        } elsif ($t eq '|') {
            push @perl_expr, '||';
        } elsif ($t eq '(' or $t eq ')') {
            push @perl_expr, $t;
        } else {
            $t =~ s/"/\\"/g;
            push @perl_expr, "index(\$line, \"$t\") >= 0";
        }
    }
    return join(' ', @perl_expr);
}

my $compiled_expr = $filter_expr ? expr_to_perl($filter_expr) : "1";

my @raw_terms;
if ($filter_expr) {
    my @quoted_terms;
    while ($filter_expr =~ /"([^"]+)"/g) {
        push @quoted_terms, $1;
    }

    my $unquoted = $filter_expr;
    $unquoted =~ s/"[^"]+"//g;
    $unquoted =~ s/[()&|]/ /g;
    my @other_terms = grep { $_ ne '' } split /\s+/, $unquoted;

    my %seen;
    @raw_terms = grep { !$seen{$_}++ } (@quoted_terms, @other_terms);
}

# DEBUG
#print "DEBUG: matched terms => @raw_terms\n";
#print "DEBUG: compiled expr => $compiled_expr\n";

open my $fh, '<', $file or die "Cannot open file $file: $!\n";

while (my $line = <$fh>) {
    chomp $line;
    if ($line =~ /^(\d+)\^\(/) {
        my $timestamp = $1;
        # Convertir epoch a formato legible
#        my $formatted_time = strftime("%Y%m%d-%H%M%S", localtime($timestamp));
        my $formatted_time = strftime("%H:%M:%S", localtime($timestamp));
#        $line =~ s/^\d+\^/\Q$formatted_time\E^/;
        $line =~ s/^\d+\^/$formatted_time^/;

        if ($timestamp >= $start_epoch && $timestamp <= $end_epoch) {
            my $eval_result = eval $compiled_expr;
            if ($@) {
                warn "Eval error: $@\n";
                next;
            }

            if ($eval_result) {
                my $colored_line = $line;
                my $color_index = 0;

                foreach my $term (@raw_terms) {
                    my $color = $colors[$color_index++ % @colors];
                    my $quoted = quotemeta($term);
                    $colored_line =~ s/($quoted)/colored($1, $color)/ge;
                }

                print "$colored_line\n";
            }
        }
    }
}
close $fh;

sub print_help {
    print <<'USO';

Uso:
  ./07.pl -f <fichero> -l|-h [-s <time>] [-e <time>] --filter <expresión>

Parámetros:
  -f <fichero>         Fichero a analizar (formato: <número_día>.dat) (opcional)
  -l                   El tiempo se pasa en formato epoch (ej: 1743034000)
  -h                   El tiempo se pasa en formato AAAAMMDD-HHMMSS o HHMMSS
  -s <inicio>          Hora de inicio (opcional)
  -e <fin>             Hora de fin (opcional)
  --filter <expresión> Expresión lógica para filtrar líneas (ver ejemplos)
  --help, -?           Muestra esta ayuda

Expresiones válidas:
  string                      → Línea que contenga "string"
  string1|string2             → Línea que contenga "string1" **o** "string2"
  string1&string2             → Línea que contenga ambos: "string1" **y** "string2"
  (string1|string2)&string3   → Agrupaciones con paréntesis
  "texto exacto"              → Para texto con espacios o caracteres especiales

Ejemplos:

  # Epoch timestamp
  ./07.pl -f 086.dat -l -s 1743034000 -e 1743034600 --filter='EA4VV'
  ./07.pl -f 086.dat -h -s 20250327-123000 --filter='EA4VV'
  ./07.pl -f 086.dat -h -s 123000 -e 125900 --filter='EA4VV'
  ./07.pl -f 086.dat --filter='EA4VV
  ./07.pl --filter='EA3CV-2'
  # Varias condiciones con OR
  ./07.pl -f 086.dat -l --filter='PC61|PC11|PC12'
  # Varias condiciones con AND
  ./07.pl -f 086.dat -l -s 1743034000 -e 1743034600 --filter='PC61^14291&EA4VV'
  ./07.pl -f 086.dat -l -s 1743034000 -e 1743034600 --filter='(PC61^14291)&EA4VV'
  ./07.pl -f 086.dat -l -s 1743034000 -e 1743034600 --filter='"PC61^14291"&EA4VV'
  # Combinación AND + OR
  ./07.pl -f 086.dat --filter='(PC61|PC11)&EA4VV'
  # Con texto literal entre comillas
  ./07.pl -f 086.dat --filter='"EA4VV^EA4RCH-5"&PC61'
  # Formato de hora humana: solo hora
  ./07.pl -f 086.dat -h -s 123000 -e 125900 --filter='EA4VV'
  # Formato complejo con AND + OR + texto literal
  ./07.pl -f 086.dat -l -e 1743034600 --filter='"PC92^EA3CV-2"&(^C^|^K^)&^H28'

USO
}
