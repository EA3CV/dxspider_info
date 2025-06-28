#
#  DB_Mysql.pm — MySQL/MariaDB backend for DXSpider users database
#
#  Description:
#    This module provides a backend implementation for DXSpider's user database
#    using MySQL or MariaDB instead of Berkeley DB (DB_File).
#
#    It allows full compatibility with the existing DXUser interface
#    and provides automatic JSON encoding/decoding of complex fields.
#
#    This backend must be explicitly enabled in DXVars.pm and requires
#    the patched version of DXUser.pm that supports dynamic backend loading.
#
#  Usage:
#    - Copy this file to: /spider/local/
#    - Add the following variables to DXVars.pm:
#
#        $db_backend = 'mysql';       # Use 'dbfile' for DB_File or 'mysql' for MySQL
#        $mysql_db     = 'dxspider';        # Database name
#        $mysql_user   = 'your_user';       # MySQL user
#        $mysql_pass   = 'your_password';   # MySQL password
#        $mysql_host   = 'localhost';       # Hostname or IP of MySQL/MariaDB server
#        $mysql_table  = 'users_new';       # Table name (usually 'users_new')
#
#    - Restart your DXSpider node after installing the module.
#
#  Required Perl modules (installable via cpanm):
#    cpanm DBI DBD::mysql
#
#    Note: DBD::mysql requires the appropriate MySQL/MariaDB client libraries
#    and headers to be present on your system (e.g. 'mariadb-dev' in Alpine).
#
#  Example Alpine packages if using Docker (from Dockerfile):
#    mariadb-dev mariadb-client
#    perl-dbd-mysql perl-db_file perl-digest-sha1
#
#  Author  : Kin EA3CV (ea3cv@cronux.net)
#  Version : 20250620 v1.1
#
#  License : This software is released under the GNU General Public License v3.0 (GPLv3)
#

package DB_Mysql;

use strict;
use warnings;
use DBI;
use JSON;
use Scalar::Util qw(blessed);
use DXVars;
use DXChannel;
use Encode;

my $dbh;
my $json = JSON->new->canonical(1);

# Field list
my @FIELDS = qw(
    call sort addr alias annok autoftx bbs believe buddies build clientoutput clientinput connlist
    dxok email ftx group hmsgno homenode isolate K lang lastin lastoper lastping lastseen lat lockout long
    maxconnect name node nopings nothere pagelth passphrase passwd pingint priv prompt qra qth rbnseeme
    registered startt user_interval version wantann wantann_talk wantbeacon wantbeep wantcw wantdx
    wantdxcq wantdxitu wantecho wantemail wantft wantgtk wantlogininfo wantpc16 wantpc9x wantpsk
    wantrbn wantroutepc19 wantrtty wantsendpc16 wanttalk wantusstate wantwcy wantwwv wantwx width xpert
    wantgrid
);

sub init {
    my ($mode) = @_;
    $dbh = DBI->connect(
        "DBI:mysql:database=$main::mysql_db;host=$main::mysql_host",
        $main::mysql_user,
        $main::mysql_pass,
        { RaiseError => 1, AutoCommit => 1, mysql_enable_utf8mb4 => 1 }
    ) or die "Error connecting to MySQL: $DBI::errstr";
    return bless {}, __PACKAGE__;
}

sub get {
    my ($call) = @_;
    $call = uc $call;
    my $sql = "SELECT * FROM `$main::mysql_table` WHERE `call` = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute($call);
    my $row = $sth->fetchrow_hashref;
    return undef unless $row;

    my %obj = %$row;

    foreach my $key (keys %obj) {
        if (defined $obj{$key}) {
            if ($obj{$key} =~ /^[\[\{]/) {
                eval { $obj{$key} = $json->decode($obj{$key}) };
            } else {
                $obj{$key} = Encode::decode('utf8', $obj{$key}) unless Encode::is_utf8($obj{$key});
            }
        }
    }

    $obj{call} ||= $call;
    $obj{sort} ||= 'U';
    $obj{group} ||= ['local'];
    $obj{registered} = 0 unless defined $obj{registered};
    $obj{priv} = 0 unless defined $obj{priv};
    $obj{lockout} = 0 unless defined $obj{lockout};

    return bless \%obj, 'DXUser';
}

sub alloc {
    my ($class, $call) = @_;
    my $self = {
        call           => uc $call,
        sort           => 'U',
        group          => ['local'],
        registered     => 0,
        priv           => 0,
        lockout        => 0,
        isolate        => 0,
        lang           => 'en',
        annok          => 1,
        dxok           => 1,
        rbnseeme       => 0,
        wantann        => 1,
        wantann_talk   => 1,
        wantbeacon     => 0,
        wantbeep       => 0,
        wantcw         => 0,
        wantdx         => 1,
        wantdxcq       => 0,
        wantdxitu      => 0,
        wantecho       => 0,
        wantemail      => 1,
        wantft         => 0,
        wantgrid       => 0,
        wantgtk        => 1,
        wantlogininfo  => 0,
        wantpc16       => 1,
        wantpc9x       => 1,
        wantpsk        => 0,
        wantrbn        => 0,
        wantrtty       => 0,
        wantsendpc16   => 1,
        wanttalk       => 1,
        wantusstate    => 0,
        wantwcy        => 1,
        wantwwv        => 1,
        wantwx         => 1,
    };
    return bless $self, 'DXUser';
}

sub put {
    my ($self) = @_;
    my $call = uc $self->{call};
    return unless $call;

    #delete $self->{annok};
    #delete $self->{dxok};
    $self->{lastseen} = $main::systime unless $self->{lastseen};

    my @values;
    my @columns = map { "`$_`" } @FIELDS;

    foreach my $f (@FIELDS) {
        my $val = $self->{$f};
        if (ref($val) && !blessed($val)) {
            push @values, $json->encode($val);
        } else {
            if (defined $val && !Encode::is_utf8($val)) {
                $val = Encode::decode('utf8', $val);
            }
            push @values, $val;
        }
    }

    my $placeholders = join(", ", ("?") x @FIELDS);
    my $updates = join(", ", map { "$_ = VALUES($_)" } @columns);

    my $sql = "INSERT INTO `$main::mysql_table` (" . join(", ", @columns) . ") VALUES ($placeholders)
               ON DUPLICATE KEY UPDATE $updates";
    my $sth = $dbh->prepare($sql);
    $sth->execute(@values);

    return 1;
}

sub new {
    my ($class, $call) = @_;
    my $self = $class->alloc($call);
    $self->put;
    return $self;
}

sub del {
    my ($self) = @_;
    my $call = uc $self->{call};
    my $sql = "DELETE FROM `$main::mysql_table` WHERE `call` = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute($call);
    return 1;
}

sub close {
    my ($self, $startt, $ip) = @_;
    $self->{lastin} = $main::systime;
    my $ref = [ $startt || $self->{startt}, $main::systime ];
    push @$ref, $ip if $ip;
    push @{$self->{connlist}}, $ref;
    shift @{$self->{connlist}} if @{$self->{connlist}} > $DXUser::maxconnlist;
    $self->put;
}

sub get_all_calls {
    my $sth = $dbh->prepare("SELECT `call` FROM `$main::mysql_table`");
    $sth->execute();
    my @calls;
    while (my ($call) = $sth->fetchrow_array) {
        push @calls, $call;
    }
    return @calls;
}

sub sync {
    my ($self) = @_;
    return put($self) if $self && ref($self) eq 'DXUser';
    return 1;
}

sub export {
    return map { get($_) } get_all_calls();
}

sub recover {
    return;
}

sub fields {
    my ($self) = @_;
    return @FIELDS;
}

1;
