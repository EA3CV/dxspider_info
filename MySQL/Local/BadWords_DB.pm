package BadWords_DB;

use strict;
use warnings;
use DBI;
use DXVars;
use DXUtil;
use DXDebug;

sub new {
    my ($class) = @_;
    my $self = {};
    bless $self, $class;

    die "BadWords_DB: \$main::mysql_badwords no definido"
        unless $main::mysql_badwords;

    $self->{table} = $main::mysql_badwords;

    $self->{dbh} = DBI->connect(
        "DBI:mysql:database=$main::mysql_db;host=$main::mysql_host",
        $main::mysql_user,
        $main::mysql_pass,
        { RaiseError => 1, AutoCommit => 1, mysql_enable_utf8mb4 => 1 }
    ) or die "BadWords_DB: error conectando a MySQL: $DBI::errstr";

    return $self;
}

# --- load_into: carga desde MySQL y genera la lista de regexes ---
sub load_into {
    my ($self, $in_ref, $relist_ref) = @_;
    my $sth = $self->{dbh}->prepare("SELECT word FROM $self->{table}");
    $sth->execute;

    my %seen;
    while (my ($word) = $sth->fetchrow_array) {
        my ($cleaned, $regex) = _process_word($word);
        next unless $cleaned && !$seen{$cleaned}++;
        $in_ref->{$cleaned} = $regex;
        push @$relist_ref, [ $cleaned, $regex ];
        dbg("BadWords_DB: cargado $cleaned = $regex") if isdbg('badword');
    }
}

sub put {
    my ($self) = @_;

    # No hacemos nada porque la persistencia es inmediata
    # mediante add_regex() y del_regex()
    dbg("BadWords_DB: put() omitido, persistencia ya gestionada en tiempo real");
    return;
}

# --- add_regex: añade nuevas palabras y las inserta en DB ---
sub add_regex {
    my ($self, $input) = @_;
    my @list = split /\s+/, $input;
    my @out;

    my $sth = $self->{dbh}->prepare("INSERT IGNORE INTO $self->{table} (word) VALUES (?)");

    foreach my $entry (@list) {
        my ($w, $regex) = _process_word($entry);
        next unless $w;
        $sth->execute($w);
        push @out, $w;
    }

    return @out;
}

# --- del_regex: elimina palabras de la DB ---
sub del_regex {
    my ($self, $input) = @_;
    my @list = split /\s+/, $input;
    my @out;

    my $sth = $self->{dbh}->prepare("DELETE FROM $self->{table} WHERE word = ?");

    foreach my $entry (@list) {
        my ($w, undef) = _process_word($entry);
        next unless $w;
        $sth->execute($w);
        push @out, $w;
    }

    return @out;
}

# --- list_regex: lista todas las palabras ---
sub list_regex {
    my ($self, $full) = @_;
    my $sth = $self->{dbh}->prepare("SELECT word FROM $self->{table} ORDER BY word");
    $sth->execute;

    my @out;
    while (my ($word) = $sth->fetchrow_array) {
        if ($full) {
            my ($cleaned, $regex) = _process_word($word);
            push @out, "$cleaned = $regex";
        } else {
            push @out, $word;
        }
    }
    return @out;
}

# --- check: comprueba si una cadena contiene alguna palabra prohibida ---
sub check {
    my ($self, $text) = @_;

    # regenerar la regex completa si es necesario
    my @relist;
    my %in;
    $self->load_into(\%in, \@relist);

    my $res;
    foreach (@relist) {
        $res .= qq{\\b(?:$_->[1]) |\n};
    }
    $res =~ s/\s*\|\s*$//;
    my $regex = qr/\b($res)/x;

    my $s = uc $text;
    my %uniq;
    my @out = grep { ++$uniq{$_}; $uniq{$_} == 1 ? $_ : () } ($s =~ /($regex)/g);

    dbg("BadWords_DB: check '$s' = '" . join(', ', @out) . "'") if isdbg('badword');
    return @out;
}

# --- Función auxiliar ---
sub _process_word {
    my ($word) = @_;
    $word = uc $word;
    $word =~ tr/01/OI/;
    my $last = '';
    my @chars;
    for (split //, $word) {
        next if $last eq $_;
        $last = $_;
        push @chars, $_;
    }

    return undef unless @chars;
    my $cleaned = join('', @chars);
    return undef unless $cleaned =~ /^\w+$/;

    my @leet = map { s/O/[O0]/g; s/I/[I1]/g; $_ } @chars;
    my $regex = join '+[\s\W]*', @leet;

    return ($cleaned, $regex);
}

1;
