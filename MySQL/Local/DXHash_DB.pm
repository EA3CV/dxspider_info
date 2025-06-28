package DXHash_DB;

use strict;
use warnings;
use DXDebug;
use DXUtil;
use DBI;

my $dbh;

sub _check_db {
    return if $dbh;
    die "\$main::mysql_bads no está definido\n" unless $main::mysql_bads;
    die "\$main::mysql_db, \$main::mysql_user, \$main::mysql_pass, \$main::mysql_host deben estar definidos"
        unless $main::mysql_db && $main::mysql_user && $main::mysql_pass && $main::mysql_host;

    $dbh = DBI->connect(
        "DBI:mysql:database=$main::mysql_db;host=$main::mysql_host",
        $main::mysql_user,
        $main::mysql_pass,
        { RaiseError => 1, AutoCommit => 1, mysql_enable_utf8mb4 => 1 }
    ) or die "Error conectando a MySQL: $DBI::errstr";
}

sub new {
    my ($pkg, $name) = @_;
    return bless { name => $name }, $pkg;
}

sub put {
    return; # No-op
}

sub add {
    my ($self, $callsign, $timestamp) = @_;
    _check_db();
    $callsign = uc($callsign);
    $timestamp ||= $main::systime;

    my $sth = $dbh->prepare(
        "REPLACE INTO $main::mysql_bads (list_name, callsign, timestamp) VALUES (?, ?, ?)"
    );
    $sth->execute($self->{name}, $callsign, $timestamp);
}

sub del {
    my ($self, $callsign, $exact) = @_;
    _check_db();
    $callsign = uc($callsign);

    my @calls = ($callsign);
    unless ($exact) {
        my $base = $callsign;
        $base =~ s|(?:-\d+)?(?:/\w)?$||;
        push @calls, map { "$base-$_" } (0..99);
    }

    my $sql = "DELETE FROM $main::mysql_bads WHERE list_name = ? AND callsign = ?";
    my $sth = $dbh->prepare($sql);

    for my $c (@calls) {
        $sth->execute($self->{name}, $c);
    }
}

sub in {
    my ($self, $callsign, $exact) = @_;
    _check_db();
    $callsign = uc($callsign);

    my $sth = $dbh->prepare(
        "SELECT timestamp FROM $main::mysql_bads WHERE list_name = ? AND callsign = ?"
    );
    $sth->execute($self->{name}, $callsign);
    my $res = $sth->fetchrow_arrayref;
    return 1 if $res;

    return 0 if $exact;

    my $base = $callsign;
    $base =~ s/-\d+$//;

    $sth->execute($self->{name}, $base);
    $res = $sth->fetchrow_arrayref;
    return $res ? 1 : 0;
}

sub set {
    my ($self, $priv, $noline, $dxchan, $line) = @_;
    return (1, $dxchan->msg('e5')) unless $dxchan->priv >= $priv;
    my @f = split /\s+/, $line;
    return (1, $noline) unless @f;

    my @out;
    for my $f (@f) {
        if ($self->in($f, 1)) {
            push @out, $dxchan->msg('hasha', uc $f, $self->{name});
            next;
        }
        $self->add($f);
        push @out, $dxchan->msg('hashb', uc $f, $self->{name});
    }

    return (1, @out);
}

sub unset {
    my ($self, $priv, $noline, $dxchan, $line) = @_;
    return (1, $dxchan->msg('e5')) unless $dxchan->priv >= $priv;
    my @f = split /\s+/, $line;
    return (1, $noline) unless @f;

    my @out;
    for my $f (@f) {
        unless ($self->in($f, 1)) {
            push @out, $dxchan->msg('hashd', uc $f, $self->{name});
            next;
        }
        $self->del($f, 1);
        push @out, $dxchan->msg('hashc', uc $f, $self->{name});
    }

    return (1, @out);
}

sub show {
    my ($self, $priv, $dxchan) = @_;
    return (1, $dxchan->msg('e5')) unless $dxchan->priv >= $priv;

    _check_db();
    my $sth = $dbh->prepare(
        "SELECT callsign, timestamp FROM $main::mysql_bads WHERE list_name = ? ORDER BY callsign"
    );
    $sth->execute($self->{name});

    my @out;
    while (my ($call, $ts) = $sth->fetchrow_array) {
        push @out, $dxchan->msg('hashe', $call, cldatetime($ts));
    }

    return (1, @out);
}

1;
