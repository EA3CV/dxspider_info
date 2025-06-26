#!/usr/bin/perl

use strict;
use warnings;
use Fcntl qw(O_RDONLY);
use DB_File;
use JSON;
use Encode qw(encode);
use DBI;

my $mysql_db   = "dxspider";
my $mysql_user = "your_user";
my $mysql_pass = "your_pass";
my $mysql_host = "127.0.0.1";
my $table_name = "users";

my $filename = '/root/volumenes/dxspider/nodo-6/local_data/users.v3j';

my $dsn = "DBI:mysql:database=$mysql_db;host=$mysql_host;mysql_enable_utf8mb4=1";
my $dbh = DBI->connect($dsn, $mysql_user, $mysql_pass, {
    RaiseError => 1,
    mysql_enable_utf8 => 1,
    AutoCommit => 1
}) or die "No se puede conectar a MySQL: $DBI::errstr";

$dbh->do("DROP TABLE IF EXISTS $table_name");

$dbh->do(q{
CREATE TABLE users (
    sort CHAR(1),
    addr TEXT,
    alias VARCHAR(16),
    annok BOOLEAN DEFAULT 0,
    autoftx BOOLEAN DEFAULT 0,
    bbs VARCHAR(20),
    believe JSON,
    buddies JSON,
    build VARCHAR(16),
    `call` VARCHAR(20) PRIMARY KEY,
    clientoutput TEXT,
    clientinput TEXT,
    connlist JSON,
    dxok BOOLEAN DEFAULT 0,
    email TEXT,
    ftx BOOLEAN DEFAULT 0,
    `group` JSON,
    hmsgno INT,
    homenode VARCHAR(128) DEFAULT NULL,
    isolate BOOLEAN DEFAULT 0,
    K BOOLEAN DEFAULT 0,
    lang CHAR(2),
    lastin BIGINT,
    lastoper BIGINT,
    lastping JSON,
    lastseen BIGINT,
    lat VARCHAR(20),
    lockout BOOLEAN DEFAULT 0,
    `long` VARCHAR(20),
    maxconnect INT,
    name VARCHAR(128),
    node VARCHAR(32),
    nopings INT,
    nothere TEXT,
    pagelth INT,
    passphrase VARCHAR(128),
    passwd VARCHAR(64),
    pingint INT,
    priv BOOLEAN DEFAULT 0,
    prompt VARCHAR(64),
    qra VARCHAR(12),
    qth TEXT,
    rbnseeme BOOLEAN DEFAULT 0,
    registered BOOLEAN DEFAULT 0,
    startt VARCHAR(32),
    user_interval INT,
    version VARCHAR(16),
    wantann BOOLEAN DEFAULT 0,
    wantann_talk BOOLEAN DEFAULT 0,
    wantbeacon BOOLEAN DEFAULT 0,
    wantbeep BOOLEAN DEFAULT 0,
    wantcw BOOLEAN DEFAULT 0,
    wantdx BOOLEAN DEFAULT 0,
    wantdxcq BOOLEAN DEFAULT 0,
    wantdxitu BOOLEAN DEFAULT 0,
    wantecho BOOLEAN DEFAULT 0,
    wantemail BOOLEAN DEFAULT 0,
    wantft BOOLEAN DEFAULT 0,
    wantgtk BOOLEAN DEFAULT 0,
    wantlogininfo BOOLEAN DEFAULT 0,
    wantpc16 BOOLEAN DEFAULT 0,
    wantpc9x BOOLEAN DEFAULT 0,
    wantpsk BOOLEAN DEFAULT 0,
    wantrbn BOOLEAN DEFAULT 0,
    wantroutepc19 BOOLEAN DEFAULT 0,
    wantrtty BOOLEAN DEFAULT 0,
    wantsendpc16 BOOLEAN DEFAULT 0,
    wanttalk BOOLEAN DEFAULT 0,
    wantusstate BOOLEAN DEFAULT 0,
    wantwcy BOOLEAN DEFAULT 0,
    wantwwv BOOLEAN DEFAULT 0,
    wantwx BOOLEAN DEFAULT 0,
    width INT,
    xpert BOOLEAN DEFAULT 0,
    wantgrid BOOLEAN DEFAULT 0
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci
});

my @fields = qw(
    sort addr alias annok autoftx bbs believe buddies build call clientoutput clientinput connlist dxok
    email ftx group hmsgno homenode isolate K lang lastin lastoper lastping lastseen lat lockout long
    maxconnect name node nopings nothere pagelth passphrase passwd pingint priv prompt qra qth rbnseeme
    registered startt user_interval version wantann wantann_talk wantbeacon wantbeep wantcw wantdx wantdxcq
    wantdxitu wantecho wantemail wantft wantgtk wantlogininfo wantpc16 wantpc9x wantpsk wantrbn wantroutepc19
    wantrtty wantsendpc16 wanttalk wantusstate wantwcy wantwwv wantwx width xpert wantgrid
);

my $placeholders = join(',', ('?') x @fields);
my $sth = $dbh->prepare("INSERT INTO $table_name (" . join(',', map { "`$_`" } @fields) . ") VALUES ($placeholders)");

my %users;
tie(%users, 'DB_File', $filename, O_RDONLY, 0, $DB_BTREE)
    or die "No se puede abrir $filename: $!";

foreach my $call (sort keys %users) {
    my $raw = $users{$call};
    my $data = eval { decode_json(encode('UTF-8', $raw)) };
    unless ($data && ref $data eq 'HASH') {
        warn "No se pudo decodificar JSON para $call\n";
        next;
    }

    my @row;
    foreach my $field (@fields) {
        my $v = $data->{$field};

        if ($field =~ /^(connlist|believe|buddies|group)$/) {
            if (!defined $v) {
                $v = '[]';
            } elsif (ref($v) eq 'ARRAY' or ref($v) eq 'HASH') {
                my $json = eval { encode_json($v) };
                warn "$call: encode_json $field fallido: $@\n" unless defined $json;
                $v = $json // '[]';
            } elsif ($v =~ /^\s*[\[{]/) {
                my $tmp = eval { decode_json($v) };
                warn "$call: decode_json $field fallido: $@\n" unless $tmp;
                $v = $tmp ? encode_json($tmp) : '[]';
            } else {
                $v = '[]';
            }
        }

        elsif ($field eq 'lastping') {
            if (!defined $v) {
                $v = '{}';
            } elsif (ref($v) eq 'HASH') {
                my $json = eval { encode_json($v) };
                warn "$call: encode_json $field fallido: $@\n" unless defined $json;
                $v = $json // '{}';
            } elsif ($v =~ /^\s*\{/) {
                my $tmp = eval { decode_json($v) };
                warn "$call: decode_json $field fallido: $@\n" unless $tmp;
                $v = $tmp ? encode_json($tmp) : '{}';
            } else {
                $v = '{}';
            }
        }

        elsif ($field =~ /^(K|isolate|lockout|priv|rbnseeme|registered|annok|dxok|ftx|autoftx|passphrase|wantann_talk|wantroutepc19|wantsendpc16|want\w+)$/) {
            $v = (!defined $v || $v eq '') ? 0 : $v;
        }

        elsif ($field =~ /^(lastin|lastoper|lastseen|pagelth|hmsgno|maxconnect|nopings|pingint|user_interval|width|xpert)$/) {
            $v = defined $v && $v ne '' ? $v : undef;
        }

        else {
            $v = defined $v ? $v : "";
        }

        push @row, $v;
    }

    $sth->execute(@row);
}

untie %users;
$dbh->disconnect;

print "✅ Exportación completada correctamente.\n";
