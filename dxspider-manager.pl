#!/usr/bin/env perl

# 
# DXSpider Manager - installation, update and restore
#
# Installs DXSpider, updates existing installations from Git (mojo or test),
# and restores previous installations or supported backups. Preserves local
# configuration and data during updates, verifies candidates and manages
# service shutdown, startup and transactional rollback.
#
# Requirements: Linux, Perl >= 5.16.1 and the system tools checked by the
# manager. 
#
# Run as root; DXSpider itself runs under its configured account.
#
# Usage (from a directory outside the DXSpider installation):
#   perl dxspider-manager.pl          # Interactive production operations as root
#   perl dxspider-manager.pl --preview # Preview / preparation only
#   perl dxspider-manager.pl --live   # Explicit production mode (compatibility)
#   perl dxspider-manager.pl --help   # Command-line help
#
# Live operations require an interactive terminal and explicit confirmation.
# Operation logs: /var/log/dxs-manager/
#
# DXSpider (C) Dirk Koopman G1TLH
# Kin EA3CV v1.1 20261125
#

use 5.016001;
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use Cwd qw(realpath);
use File::Basename qw(dirname basename);
use File::Spec;
use File::Path qw(remove_tree make_path);
use Fcntl qw(:flock :mode :DEFAULT);
use IO::Handle;
use IO::Select;
use IO::Socket::INET;
use Socket qw(AF_INET AF_INET6 inet_ntop);
use Digest::SHA qw(sha256_hex);
use JSON::PP;
use POSIX qw(WNOHANG setsid);
use Time::HiRes qw(sleep);
use Errno qw(ENOENT);

use constant VERSION => '1.1';

my $live_requested = 0;
my $preview_requested = 0;
my $live_enabled = 0;
sub LIVE_ENABLED { return $live_enabled; }
my @persistent = qw(local local_data local_cmd filter connect scripts);
my @backup_empty = map {"local_data/$_"} qw(debug log tmp wcy wwv);
my @stop = qw(admin web spider);
my @start = reverse @stop;
my %units = (admin => 'dxweb-admin.service', web => 'dxweb.service', spider => 'dxspider.service');
my @remote = ('git://scm.dxcluster.org/spider', 'https://github.com/EA3CV/dxspider.git');
our $base = "";
my $check_remote = 0;
my ($manual_launch_dir, $spider_port, $web_port, $admin_port) = ('', 0, 0, 0);
my ($mode, $installation, $branch, $backup, $allow_dirty, $fault, $role, $token, $reserve, $help,
    $probe_config) = ('interactive', '/spider', 'mojo', 0, 0, '', '', '', 0, 0, '');
my @scan_roots;
Getopt::Long::Configure(qw(no_auto_abbrev no_ignore_case));
GetOptions(
    'live'                  => \$live_requested,
     'preview'               => \$preview_requested,
    'scan-root=s@'          => \@scan_roots,
    'mode=s'                => \$mode,
    'installation=s'        => \$installation,
    'branch=s'              => \$branch,
    'base=s'                => \$base,
    'backup!'               => \$backup,
    'accept-local-changes!' => \$allow_dirty,
    'fault=s'               => \$fault,
    'role=s'                => \$role,
    'token=s'               => \$token,
    'reserve-gib=i'         => \$reserve,
    'probe-config=s'        => \$probe_config,
    'check-remote!'         => \$check_remote,
    'manual-launch-dir=s'   => \$manual_launch_dir,
    'spider-port=i'         => \$spider_port,
    'web-port=i'            => \$web_port,
    'admin-port=i'          => \$admin_port,
    'help'                  => \$help
) or die "Invalid arguments\n";
die "Unexpected arguments\n" if @ARGV;
my $script = realpath($0) or die "Cannot resolve executable\n";
my $json = JSON::PP->new->canonical->ascii;
my ($root, $work, $lock, $j, $fixture, $owner, $group);
my $systemd_fixture;
our $approved_services;
my $home_fs = 0; # owner-only filesystem worker for a user-owned parent
my $home_anchor;
my $fs_child = 0;
$| = 1;
umask 0077;
$ENV{LC_ALL} = 'C';
$ENV{PATH} = '/usr/sbin:/usr/bin:/sbin:/bin';
delete @ENV{grep { /\A(?:GIT_|XDG_CONFIG_HOME\z|XDG_CACHE_HOME\z|PERL5OPT|PERL5LIB|BASH_ENV|ENV\z)/ } keys %ENV};
$ENV{GIT_TERMINAL_PROMPT} = 0;
$ENV{GIT_CONFIG_NOSYSTEM} = 1;
$ENV{GIT_CONFIG_GLOBAL} = '/dev/null';
$ENV{GIT_OPTIONAL_LOCKS} = 0; # read-only status must not refresh the live index

# ==========================================================================
# 01. Common utilities and durable filesystem operations
# ==========================================================================

sub fail {
    die "ERROR: $_[0]\n"
}

sub run {
    my @cmd = @_;
    system { $cmd[0] } @cmd;
    fail("command failed ($?): $cmd[0] $cmd[1]") if $? != 0
}

sub capture_status {
    my @cmd = @_;
    open my $h, '-|', @cmd or fail("exec $cmd[0]: $!");
    binmode $h;
    local $/;
    my $s = <$h>//'';
    close $h;
    return ($? == 0, $s)
}

sub capture {
    my ($ok, $s) = capture_status(@_);
    fail("command failed: $_[0] $_[1]") unless $ok;
    return $s
}

sub read_file {
    my ($p) = @_;
    open my $h, '<', $p or fail("read $p: $!");
    binmode $h;
    local $/;
    my $s = <$h>//'';
    close $h or fail("close $p: $!");
    return $s
}

sub optional_read {
    my ($p) = @_;
    open my $h, '<', $p or return '';
    local $/;
    my $s = <$h>//'';
    close $h;
    return $s
}

sub sync_dir {
    my ($p) = @_;
    open my $h, '<', $p or fail("open directory $p: $!");
    $h->sync or fail("sync directory $p: $!");
    close $h or fail("close $p: $!")
}

sub write_file {
    my ($p, $s) = @_;
    sysopen my $h, $p, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0600 or fail("create $p: $!");
    binmode $h;
    print {$h} $s or fail("write $p: $!");
    $h->flush or fail("flush $p: $!");
    $h->sync or fail("sync $p: $!");
    close $h or fail("close $p: $!")
}

sub atomic_write {
    my ($p, $s) = @_;
    my $tmp = "$p.next.$$";
    write_file($tmp, $s);
    rename($tmp, $p) or fail("rename $p: $!");
    sync_dir(dirname($p))
}

sub ident {
    my ($p) = @_;
    my @s = lstat($p);
    if (!@s) {
        return undef if $! == ENOENT;
        fail("lstat $p: $!")
    }
    fail("not a real directory: $p") unless S_ISDIR($s[2]);
    return "$s[0]:$s[1]"
}

sub same {
    defined($_[0]) && defined($_[1]) && $_[0] eq $_[1]
}

sub exists_path {
    -e $_[0] || -l $_[0]
}

sub move_tree {
    my ($a, $b) = @_;
    fail("occupied destination $b") if exists_path($b);
    rename($a, $b) or fail("rename $a -> $b: $!");
    sync_dir(dirname($a));
    sync_dir(dirname($b)) if dirname($a) ne dirname($b)
}

sub random_token {
    open my $h, '<', '/dev/urandom' or fail("urandom: $!");
    read($h, my $b, 24) == 24 or fail('urandom short read');
    close $h;
    return unpack('H*', $b)
}

sub checkpoint {
    my ($state) = @_;
    $j->{state} = $state;
    $j->{sequence} = 1+($j->{sequence}//0);
    $j->{updated} = time;
    atomic_write("$work/journal.json", $json->encode($j)."\n");
    print "STATE $state seq=$j->{sequence}\n"
}

sub inject {
    my ($point) = @_;
    return unless $fixture;
    if ($point eq 'new-renamed' && $fault eq 'sigkill-after-rename') {
        print "FAULT SIGKILL\n";
        kill 'KILL', $$;
        POSIX::_exit(74)
    }
    return unless $fault eq $point;
    print "FAULT $point\n";
    if ($point =~  /^(?:crash-|old-renamed|new-renamed|committed)/) {
        POSIX::_exit(73)
    }
    fail("injected $point")
}

sub under {
    my ($p, $r) = @_;
    return defined($p) && ($p eq $r || index($p, "$r/") == 0)
}

sub path_check {
    my ($p) = @_;
    fail("absolute canonical path required: $p") unless $p =~ m{\A/[^\x00-\x1f]+\z} && $p !~ m{(?:^|/)\.\.?(/|$)|//|/$};
    return $p
}

sub find_tool {
    my ($t) = @_;
    return (grep {-x $_ && !-d $_} map {"$_/$t"} split /:/, $ENV{PATH})[0]
}

sub tools_check {
    for my $t (qw(git cp tar rsync df sync timeout stat)) {
        fail("missing tool $t") unless find_tool($t)
    }
    my $v = capture('rsync', '--version');
    fail('rsync lacks required metadata support') unless $v =~  /\bsymtimes\b/ && $v =~  /\bACLs\b/
        && $v =~  /\bxattrs\b/ && $v !~ /\bno (?:symtimes|ACLs|xattrs)\b/;
    fail('GNU tar required') unless capture('tar', '--version') =~  /GNU tar/;
    fail('GNU cp required') unless capture('cp', '--version') =~  /GNU coreutils/;
    if (!$fixture && defined($owner) && $owner != $>) {
        fail('runuser missing') unless find_tool('runuser')
    }
}

# Only a contiguous, protected root-owned ancestor may contain the durable
# lock/journal. The remaining path must belong to a single non-root account.
# We do NOT chown/chmod the user's HOME or trust a journal located inside it.

sub transaction_layout {
    my ($r, $uid) = @_;
    path_check($r);
    my $parent = dirname($r);
    fail('noncanonical parent') unless (realpath($parent)//'') eq $parent;
    my @chain;
    my $p = $parent;
    while (1) {
        unshift @chain, $p;
        last if $p eq '/';
        $p = dirname($p);
    }
    my ($anchor, $account);
    my $dev = (stat($parent))[0];
    for my $d (@chain) {
        my @st = lstat($d);
        fail("unsafe transaction ancestor $d") unless @st && S_ISDIR($st[2]) && !($st[2]&0022);
        if (!defined($account) && $st[4] == 0) {
            $anchor = $d;
            next;
        }
        $account = $st[4] unless defined($account);
        fail("mixed/untrusted owners in installation ancestry: $d") unless $account>0
            && $st[4] == $account;
        fail('installation ancestry crosses filesystem') unless $st[0] == $dev;
    }
    fail('no protected same-filesystem transaction anchor') unless defined($anchor)
        && (stat($anchor))[0] == $dev;
    if (defined $account) {
        fail('installation owner differs from writable parent owner') if defined($uid)
            && $uid != $account;
        fail('home layout requires root supervisor') unless $> == 0 || $fs_child;
        return {anchor => $anchor, home => 1, uid => $account, work => File::Spec->catdir($anchor,
            '.dxs-updater-home-'.substr(sha256_hex($r), 0, 32))};
    }
    return {anchor => $parent, home => 0, work => File::Spec->catdir($parent,
        '.dxs-updater-'.basename($r))};
}

sub tree_work {
    return $home_fs && defined($work)?"$work/trees":$work;
}

# File operations under a user's writable parent execute in a child with all
# real/effective/saved/fs UIDs and GIDs changed permanently. The root parent
# retains only the durable lock/journal and the bounded service-control logic.
# The inherited lock remains held until the worker finishes, even if the
# supervisor is killed. Signals to the supervisor are deferred during a phase.

sub owner_file_call {
    my ($cb) = @_;
    return $cb->() unless $home_fs && !$fs_child;
    fail('owner filesystem worker requires root and non-root account') unless $> == 0
        && defined($owner)
        && defined($group) && $owner>0 && $group>0;
    my @pw = getpwuid($owner);
    fail('unknown filesystem account') unless @pw && $pw[2] == $owner;
    my $groups = capture('id', '-G', '--', $pw[0]);
    fail('invalid account group list') unless $groups =~ /\A\d+(?:[ \t]+\d+)*\s*\z/;
    my @gids = grep {length} split /\s+/, $groups;
    fail('account is not a member of the installation group') unless grep {$_ == $group} @gids;
    my $dw = tree_work();
    STDOUT->flush; STDERR->flush;
    pipe(my $rd, my $wr) or fail('filesystem worker pipe');
    my $pid = fork();
    fail('filesystem worker fork') unless defined $pid;
    if (!$pid) {
        close $rd;
        # Do not release the transaction lock in this child. It protects the
        # in-flight filesystem phase if the parent dies unexpectedly.
        my $result;
        my $ok = eval {
            $) = join(' ', $group, @gids);
            $( = $group;
            POSIX::setgid($group) == 0 or fail('filesystem worker setgid');
            POSIX::setuid($owner) == 0 or fail('filesystem worker setuid');
            my $status = read_file('/proc/self/status');
            fail('filesystem worker credentials not permanently dropped')
                unless $status =~ /^Uid:\s+$owner\s+$owner\s+$owner\s+$owner\s*$/m
                && $status =~ /^Gid:\s+$group\s+$group\s+$group\s+$group\s*$/m
                && $status =~ /^CapEff:\s+0+\s*$/m && $status =~ /^CapPrm:\s+0+\s*$/m;
            fail('filesystem worker UID/GID mismatch') unless $< == $owner && $> == $owner
                && 0+$( == $group && 0+$) == $group;
            $fs_child = 1;
            $home_fs = 0;
            $work = $dw;
            $ENV{HOME} = $pw[7]; $ENV{USER} = $ENV{LOGNAME} = $pw[0];
            delete @ENV{qw(TMPDIR TEMP TMP)};
            if (defined($work) && -d "$work/tmp-owner" && !-l "$work/tmp-owner") {
                $ENV{TMPDIR} = $ENV{TEMP} = $ENV{TMP} = "$work/tmp-owner";
            }
            chdir('/') or fail('filesystem worker cwd');
            $result = $cb->();
            1;
        };
        my $err = $@;
        my $msg = eval {$json->encode({ok => $ok?1:0, result => $result, error => $err})};
        $msg = $json->encode({ok => 0, error => 'filesystem worker could not encode result'})
            unless defined $msg;
        print {$wr} $msg;
        close $wr;
        STDOUT->flush; STDERR->flush;
        POSIX::_exit($ok?0:1);
    }
    close $wr;
    my $interrupted = 0;
    local $SIG{INT} = sub {$interrupted = 1};
    local $SIG{TERM} = sub {$interrupted = 1};
    my $raw = '';
    while (1) {
        my $n = read($rd, my $chunk, 65536);
        if (!defined($n)) {next if $!{EINTR}; last;}
        last unless $n;
        # Consume the complete pipe before waiting even if the child exceeded
        # the limit; never let a blocked worker outlive its transaction lock.
        $raw .= $chunk if length($raw) <= 16*1048576;
    }
    close $rd;
    while (waitpid($pid, 0)<0) {
        next if $!{EINTR};
        fail('filesystem worker wait failed');
    }
    my $rc = $?;
    fail('interrupted during filesystem phase; worker has exited') if $interrupted;
    fail('filesystem worker response too large') if length($raw)>16*1048576;
    my $v = eval {$json->decode($raw)};
    fail('filesystem worker terminated without valid result') unless ref($v) eq 'HASH';
    fail('owner filesystem phase: '.($v->{error}//'failed')) unless $rc == 0 && $v->{ok};
    my $result = $v->{result};
    utf8::downgrade($result, 1) if defined($result) && !ref($result);
    return $result;
}

# Fail before stopping services when a non-root copy cannot preserve metadata.
# This covers the owner/group layout produced by the Bash installer. Mixed
# ownership is not silently converted or copied with elevated privileges.
sub owner_tree_preflight {
    my ($tree) = @_;
    return 1 unless $home_fs || $fs_child;
    return owner_file_call(sub {owner_tree_preflight($tree)}) if $home_fs;
    my %groups = map {$_ => 1} split /\s+/, $);
    my $dev = (stat($tree))[0];
    walk($tree, sub {
        my ($path, $st) = @_;
        fail("file ownership cannot be preserved as SYSOP: $path") unless $st->[4] == $owner
            && $groups{$st->[5]};
    }, $dev);
    return 1;
}

sub validate_root {
    my ($p, $missing) = @_;
    path_check($p);
    my $parent = dirname($p);
    fail('noncanonical parent') unless (realpath($parent)//'') eq $parent;
    fail('unsafe executable inside installation') if under($script, $p);
    fail('installation symlink or noncanonical') if -l $p || (exists_path($p)
        && (realpath($p)//'') ne $p);
    fail('installation missing') if !$missing && !-d $p;
    ($owner, $group) = (undef, undef);
    if (-d $p) {
        fail('filesystem mismatch') unless (stat($p))[0] == (stat($parent))[0];
        fail('missing real cluster.pl') unless -f "$p/perl/cluster.pl" && !-l "$p/perl"
            && !-l "$p/perl/cluster.pl";
        my @s = stat("$p/perl/cluster.pl");
        ($owner, $group) = @s[4, 5];
    }
    my $layout = transaction_layout($p, $owner);
    $home_fs = $layout->{home};
    $home_anchor = $layout->{anchor};
    return $p;
}

sub no_mounts {
    my ($p) = @_;
    for my $line (split /\n/, read_file('/proc/self/mountinfo')) {
        my @a = split / /, $line;
        next unless @a>5;
        my $m = $a[4];
        $m =~ s/\\([0-7]{3})/chr(oct($1))/ge;
        fail("mount within installation: $m") if under($m, $p)
    }
}

sub acquire {
    my ($create) = @_;
    my $layout = transaction_layout($root, $owner);
    $home_fs = $layout->{home};
    $home_anchor = $layout->{anchor};
    $work = $layout->{work};
    # Stable lock is deliberately outside the transaction that may be archived.
    my $lp = "$work.lock";
    sysopen($lock, $lp, O_RDWR|O_NOFOLLOW|($create?O_CREAT:0), 0600) or fail("lock: $!");
    my @l = stat($lock);
    fail('unsafe lock') unless @l && S_ISREG($l[2]) && $l[3] == 1 && $l[4] == $> && !($l[2]&0077);
    fail('another updater holds the lock') unless flock($lock, LOCK_EX|LOCK_NB);
    ensure_workspace($create);
}

sub ensure_workspace {
    my ($create) = @_;
    my $parent = $home_anchor//dirname($root);
    my @s = stat($parent);
    if (!exists_path($work)) {
        fail('no transaction workspace') unless $create;
        my $mode = $home_fs?0711:$fixture?0700:0711;
        mkdir($work, $mode) or fail("mkdir $work: $!");
        chmod($mode, $work) or fail('workspace mode');
        sync_dir($parent)
    }
    my @w = lstat($work);
    fail('unsafe workspace') unless @w && S_ISDIR($w[2]) && $w[4] == $> && !($w[2]&0066)
        && $w[0] == $s[0];
    if ($home_fs) {
        if (!defined($owner) || !defined($group)) {
            my $saved = protected_json("$work/journal.json");
            fail('missing active tree and mismatched workspace account')
                unless ($saved->{root}//'') eq $root
                && ($saved->{owner}//0) == transaction_layout($root, undef)->{uid}
                && ($saved->{group}//0)>0;
            ($owner, $group) = @$saved{qw(owner group)};
        }
        my $tree = "$work/trees";
        if (!exists_path($tree)) {
            fail('missing retained tree workspace') unless $create
                && !exists_path("$work/journal.json");
            mkdir($tree, 0700) or fail('create owner tree workspace');
            chown($owner, $group, $tree) == 1 or fail('assign owner tree workspace');
            sync_dir($work);
        }
        my @t = lstat($tree);
        fail('unsafe owner tree workspace') unless @t && S_ISDIR($t[2]) && $t[4] == $owner
            && $t[5] == $group && !($t[2]&0077) && $t[0] == $w[0];
    }
}

sub configure_tmp {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {configure_tmp(@args)});
    }
    for my $d ('tmp-root', 'tmp-owner') {
        my $p = "$work/$d";
        my $uid = $d eq 'tmp-owner' && defined($owner)?$owner:$>;
        my $gid = $d eq 'tmp-owner' && defined($group)?$group:(stat($work))[5];
        if (!exists_path($p)) {
            mkdir($p, 0700) or fail("mkdir $p");
            chown($uid, $gid, $p) == 1 or fail("chown $p")
        }
        my @s = lstat($p);
        fail("unsafe temporary directory $p") unless @s && S_ISDIR($s[2]) && $s[4] == $uid
            && !($s[2]&0077);
    }
    $ENV{TMPDIR} = $ENV{TEMP} = $ENV{TMP} = "$work/tmp-root";
}

sub load_journal {
    fail('missing journal') unless -f "$work/journal.json" && !-l "$work/journal.json";
    $j = $json->decode(read_file("$work/journal.json"));
    fail('journal mismatch') unless $j->{version} == 1 && $j->{root} eq $root
        && $j->{fixture} == ($fixture?1:0) && ($j->{systemd_fixture}//0) == ($systemd_fixture?1:0)
        && $j->{branch} =~  /\A(?:mojo|test)\z/;
    fail('journal layout/account mismatch') if ($j->{home_layout}//0) != ($home_fs?1:0) || ($home_fs
        && (($j->{owner}//0) != $owner || ($j->{group}//0) != $group));
}

# ==========================================================================
# 02. Filesystem inventory and capacity planning
# ==========================================================================

sub walk {
    my ($p, $cb, $dev, $estimate, $prune) = @_;
    my @s = lstat($p);
    if (!@s) {
        if ($estimate && $! == ENOENT) {
            $$estimate++;
            return
        }
        fail("lstat $p: $!")
    }
    fail("different filesystem: $p") if $s[0] != $dev;
    fail("special file: $p") unless S_ISDIR($s[2]) || S_ISREG($s[2]) || S_ISLNK($s[2]);
    $cb->($p, \@s);
    if (S_ISDIR($s[2]) && !($prune && $prune->($p))) {
        if (!opendir(my $dh, $p)) {
            if ($estimate && $! == ENOENT) {
                $$estimate++;
                return
            }
            fail("opendir $p: $!")
        } else {
            my @n = sort grep {$_ ne '.' && $_ ne '..'} readdir $dh;
            closedir $dh;
            walk("$p/$_", $cb, $dev, $estimate, $prune) for @n
        }
    }
}

# Estimate a real copy, not the size of an already existing rollback tree.
# Count hardlinks once per copy set; round regular files conservatively and
# use the larger of allocated and apparent size (also safe for sparse files).

sub entry_bytes {
    my ($s) = @_;
    my $allocated = $s->[12]*512;
    my $apparent = S_ISREG($s->[2])?int(($s->[7]+4095)/4096)*4096:0;
    my $data = $allocated>$apparent?$allocated:$apparent;
    return $data+4096; # filesystem metadata allowance per inode
}

sub inventory_sizes {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {inventory_sizes(@args)});
    }
    my ($r, $strict, $detect_db, @parts) = @_;
    my $prune = ref($parts[0]) eq 'CODE'?shift(@parts):undef;
    my ($b, $n, $vanished) = (0, 0, 0);
    my $dev = (stat($r))[0];
    my (%seen, %files, @db);
    for my $p (@parts) {
        walk("$r/$p", sub{
            my ($path, $s) = @_;
            my $k = "$s->[0]:$s->[1]";
            if (!$seen{$k}++) {
                ++$n;
                $b += entry_bytes($s)
            }
            return unless $detect_db && S_ISREG($s->[2]);
            $files{$path} = entry_bytes($s);
            return unless $s->[7] >= 16;
            if (!sysopen(my $fh, $path, O_RDONLY|O_NOFOLLOW)) {
                if (!$strict && $! == ENOENT) {
                    ++$vanished;
                    return
                }
                fail("open SQLite signature $path: $!")
            }
            else {
                binmode $fh;
                my $nread = read($fh, my $header, 16);
                fail("read $path: $!") unless defined $nread;
                close $fh or fail("close $path: $!");
                push @db, $path if $nread == 16 && $header eq "SQLite format 3\0";
            }
        }, $dev, $strict?undef:\$vanished, $prune)
    }
    print "CAPACITY observation: $vanished transient entries disappeared; estimate only\n" if $vanished;
    my ($scratch, $sn) = (0, 0);
    for my $db (@db) {
        my ($dbb, $dbn) = (8192, 2);
        for my $suffix ('', '-wal', '-shm', '-journal') {
            my $p = "$db$suffix";
            next unless exists $files{$p};
            $dbb += $files{$p};
            ++$dbn
        }
        $scratch = $dbb if $dbb>$scratch;
        $sn = $dbn if $dbn>$sn;
    }
    return {bytes => $b, inodes => $n, sqlite_bytes => $scratch, sqlite_inodes => $sn, dbs => \@db};
}

# The backup retains the directory entries and metadata but never their contents.
# The candidate and rollback manifests use the full, unfiltered tree.

sub backup_prune {
    my ($r) = @_;
    my %skip = map {("$r/./$_", 1)} @backup_empty;
    return sub {
        exists $skip{$_[0]}
    };
}

sub backup_sizes {
    my ($r, $strict) = @_;
    return inventory_sizes($r, $strict, 0, backup_prune($r), '.')
}

sub backup_filters {
    return map {"--exclude=/$_/*"} @backup_empty
}

sub nonpersistent_parts {
    my ($r) = @_;
    opendir my $dh, $r or fail("open $r: $!");
    my %exclude = map {$_ => 1} ('.', '..', @persistent);
    my @p = sort grep {!$exclude{$_}} readdir $dh;
    closedir $dh;
    return @p;
}

sub max_of {
    return $_[0]>$_[1]?$_[0]:$_[1]
}

sub capacity_margin {
    my ($b, $n) = @_;
    return(max_of(max_of(64*1048576,
        int(($b+19)/20)),$reserve*1073741824),max_of(128,int(($n+19)/20)));
}

sub available_capacity {
    my @d = split /\s+/, (split /\n/, capture('df', '-PB1', dirname($root)))[-1];
    my @i = split /\s+/, (split /\n/, capture('df', '-Pi', dirname($root)))[-1];
    fail('df result invalid') unless ($d[3]//'') =~ /^\d+$/ && ($i[3]//'') =~ /^\d+$/;
    return(0+$d[3], 0+$i[3]);
}

sub capacity_check {
    my ($need, $in, $strict) = @_;
    my ($free, $free_n) = available_capacity();
    print "CAPACITY bytes=$free required=$need inodes=$free_n required=$in strict=", ($strict?1:0),
        "\n";
    fail('insufficient bytes or inodes') if $free<$need || $free_n<$in;
}

sub capacity {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return @{owner_file_call(sub {[capacity(@args)]})};
    }
    my ($download, $strict, $report_only) = @_;
    my $restoring = (!$download && $j && ($j->{operation}//'') eq 'restore' && defined($work)
        && -d "$work/candidate");
    my $p = inventory_sizes($restoring?"$work/candidate":$root, $strict, 1, @persistent);
    if ($restoring) { $p->{bytes} = 0; $p->{inodes} = 0; } # already copied historical data
    my ($gb, $gn, $bb, $bn) = (0, 0, 0, 0);
    if ($download) {
        my $g = inventory_sizes($root, $strict, 0, nonpersistent_parts($root));
        # Before download only: existing code and Git, not runtime data. Factor
        # two and a 32 MiB floor allow growth; this is not a remote download quota.
        ($gb, $gn) = (max_of(32*1048576, 2*$g->{bytes}), max_of(256, 2*$g->{inodes}));
    }
    if ($backup) {
        my $b = backup_sizes($root, $strict);
        ($bb, $bn) = @$b{qw(bytes inodes)};
    }
    # Scratch copies are checked and removed one by one BEFORE optional backup.
    # Peak extra space is the maximum of those phases, not their sum.
    my $subtotal = $gb+$p->{bytes}+max_of($p->{sqlite_bytes}, $bb);
    my $subn = $gn+$p->{inodes}+max_of($p->{sqlite_inodes}, $bn);
    my ($margin, $mn) = capacity_margin($subtotal, $subn);
    my $need = $subtotal+$margin;
    my $in = $subn+$mn;
    print "CAPACITY DETAIL git_estimate=$gb persistence=$p->{bytes} sqlite_peak=$p->{sqlite_bytes} backup=$bb rollback_rename=0 margin=$margin databases=", scalar(@{$p->{dbs}}), "\n";
    print "CAPACITY INODES git_estimate=$gn persistence=$p->{inodes} sqlite_peak=$p->{sqlite_inodes} backup=$bn margin=$mn\n";
    unless ($report_only) {
        capacity_check($need, $in, $strict);
        inject('space')
    }
    return($need, $in, {git => $gb, persist => $p->{bytes}, sqlite => $p->{sqlite_bytes},
        backup => $bb,
        margin => $margin});
}

# ==========================================================================
# 03. Git sources, integrity and version metadata
# ==========================================================================

sub as_owner {
    my @cmd = @_;
    return @cmd if ($fixture && !$home_fs) || !defined($owner) || $owner == $>;
    fail('cannot switch to installation owner') unless $> == 0;
    my $u = getpwuid($owner);
    my $g = getgrgid($group);
    fail('unknown installation owner/group') unless defined($u) && defined($g);
    my $tw = tree_work();
    my @tmp = defined($tw) && -d "$tw/tmp-owner"?('env', "TMPDIR=$tw/tmp-owner",
        "TMP=$tw/tmp-owner",
        "TEMP=$tw/tmp-owner"):();
    return ('runuser', '-u', $u, '-g', $g, '--', @tmp, @cmd);
}

sub git {
    my ($r, @args) = @_;
    return ('timeout', '180', as_owner('git', '-c', 'core.fsmonitor=false', '-c',
        'core.hooksPath=/dev/null', '-C', $r, @args))
}

sub git_value {
    my ($r, @args) = @_;
    my $s = capture(git($r, @args));
    chomp $s;
    return $s
}
# The exact malformed historical tag objects observed on Dirk's server on
# 2026-11-24. Never suppress an fsck diagnostic or modify any live repository.
sub legacy_tag_known {
    my ($id) = @_;
    my %known=map {$_=>1} qw(
  04e6dff018dcda66ddab7a87156f291bb23d1517
  15c8b9c8860d059a10facb0e26e4794041a7b41c
  1c62a66d708ae816f65f1c6b4a9ae26121fbf1e6
  23821fa6021dfa84d894e13cb36ac20ebc69ccbc
  241937815f94927b97f40a145c4457b529a8011a
  2b06ba2a27bc1bdc8654c3fc35224b9b6e07b0db
  32c509c5ba096b9c42e75a6f462067659b263fa8
  347b41a6de489a3a6e813ebd41534b05fc352019
  3a90d72e8dd56864b9547e5984c2aae1435da2c7
  3c196f20def468017ed8e7d7958133be08fc217b
  3d876ee439955408542d90b45ce6d0169ef261af
  3e905225447b5c9368993ff6ca9ffc0a2ea447cd
  3e97ca1ee1386bf082ffd0dafafdc8f7281071ee
  3eda8af506226b76dc2c516a5ab955c838b0cf6c
  49b58d78173f71f0cf2662d7ed853a46c994b197
  4b94745bd5d5376500c75c92ad61e5b4367685fa
  4c59d1c82c05dd8dd36fcf5a6c9375f91fafa69d
  4e023b306b2e9a600c445c030027c1c729c601f4
  51da7006b6a235d96963cb4395d1f12f17424d7e
  5c9b13eb6845c70f3df66ccc8e726220c83b3074
  5cfa31743b1c94671a59c5e05a0b44cfc5798a23
  5f5a5406ad4fd897e4dea2b350dfe89638bcd988
  61a638116636f57f1f9aa4aefce0ab67f481f8bd
  63536f03c5f16716edae155441f5210429b82ed2
  68a71e7d4cb7bdb19162413094333fb8a0b09bfa
  72e52902ea17eaaae6ee995eda72ead749badc79
  787c35a0152f973a2e8baf08fd8f0ecd4ea2b90a
  7e6194828cc5bd953e47e518aad1534b53b5fac7
  800a992226041d9cb643997784abeaa49f7002b9
  8171e6fc724e776db91117e7456447fb48be3209
  81b7ced6412a617dbe80a2817ddba80c048c4935
  82a069702aa7b9e345886974fe4481de05beff03
  858326cf472f6e94a55630b24f7fb0a2bc901643
  8a54f3d379a42a7a233cb9d0da6a17bc7f637bbf
  94ada69b423b3fbb6f2ab58b323fc45544209b38
  9844964fc5b5eb94c9633f57ce9a32262e1cd437
  9b90badf1f483d234fae5c4cc98c2b82cafe0d5d
  9d2de4abba1085fd8f5e2d89d96d6f6af7d1b3b9
  a48cd40af696e44023a2f7a797f1e90e809b88a0
  ae9483efc49c871915c77f61aa2d44f69a0d7a01
  b0b2162e805383c601ab2a1c21d94143244fd3af
  b1ee33d8e6d949785f4b8f459c924bb16ebc0bc8
  b228f13e37f7396da3d048f8d5234cb0b9b05f5c
  bc6fc0966a8b720f71928507656768d24ddfef9f
  c2eb9f292a487c2bb4f05c466023886af1b20294
  c57cca0b4d7e0bfe67d6e4d024af9d8d4faed458
  c6e950b85b66a57a72cddd9340cb4ce9cbac4e64
  c846667614942b33a490321ca90cfcad63bfb882
  d113228944cb418f7ec90f77446691f72753bf1f
  d84e2b9c2fbed1a5f02a5a5de5db7afa34366deb
  dc81979d9c2ac5ffa3f627bf3c82ee615817158a
  dee6eca36270fb7710f7a7ac9f15c5c1ce2cf0a8
  dfbc130ea762b544af94310c7c317a8be094d992
  e455a79f977d41f15294bc991748fa897d93ef1e
  ea9a9c0524348e671ccfe1d4a6f012efbce2b98f
  ecdb343cb20c9305165fbdbc447e78f54ae94413
  f715304bd13d36b5c7240ffb2b1ff2249fbbfd1c
  f991742b43b4c5a309b2ddf8d52328582d18afc9
 );
    return $known{$id};
}

sub fsck_report {
    my ($r) = @_;
    my @cmd = git($r, 'fsck', '--full', '--no-dangling', '--no-progress');
    my $pid = open(my $fh, '-|');
    fail('fsck fork failed') unless defined $pid;
    if (!$pid) {
        open STDERR, '>&', STDOUT or POSIX::_exit(126);
        exec {$cmd[0]} @cmd or POSIX::_exit(127)
    }
    binmode $fh;
    my $out = do{
        local $/;
        <$fh>//''
    };
    close $fh;
    my $status = $?;
    print $out if length $out;
    return($status, $out);
}

sub repair_legacy_tags {
    my ($r, $url) = @_;
    my ($status, $out) = fsck_report($r);
    return undef if $status == 0;
    fail('Git fsck failed; no historical tag repair for this source') unless $url eq $remote[0];
    # fsck's object/pack error bits vary with loose vs packed objects. Never
    # accept a timeout, a signal, a missing-object bit or another diagnostic.
    fail('Git fsck failed with unexpected status') unless $status == 256 || $status == 1024
        || $status == 1280;
    my %bad;
    for my $line(split /\n/, $out) {
        fail('Git fsck has an unapproved diagnostic')
            unless $line =~  /\Aerror in tag ([0-9a-f]{40}): missingSpaceBeforeDate: invalid author\/committer line - missing space before date\z/;
        my $id = $1;
        fail('Git fsck has an unknown historical tag') unless legacy_tag_known($id);
        $bad{$id} = 1;
    }
    fail('Git fsck failure without recognized diagnostics') unless keys %bad;
    my %reachable = map {$_ => 1} split /\n/, capture(git($r, 'rev-list', '--objects', '--all',
        '--reflog', '--indexed-objects', '--no-object-names'));
    for my $id (sort keys %bad) {
        fail('malformed tag is reachable; cannot repair') if $reachable{$id};
        fail('malformed object is not a tag') unless git_value($r, 'cat-file', '-t', $id) eq 'tag'
    }

    # Only stage_git calls this on a fresh disposable clone, never on source,
    # active tree, recovery tree, or an accepted candidate. A normal repack and
    # prune removes unreferenced objects; all reachable objects are retained.
    # Check temporary pack capacity before writing. Full integrity is mandatory
    # afterwards, with the default severity of every fsck diagnostic unchanged.

    my $sz = inventory_sizes($r, 1, 0, '.git');
    my ($mb, $mn) = capacity_margin(2*$sz->{bytes}, $sz->{inodes});
    capacity_check(2*$sz->{bytes}+$mb, $sz->{inodes}+$mn, 1);
    print 'GIT LEGACY TAG CLEANUP: ', scalar(keys %bad),
        " unreachable known tags; fresh clone only\n";
    run(git($r, '-c', 'gc.auto=0', 'repack', '-a', '-d'));
    run(git($r, 'prune', '--expire=now'));
    my ($after) = fsck_report($r);
    fail('Git fsck still fails after isolated cleanup') if $after;
    # Recheck that every previously reachable object still exists in the same
    # reachable set, in addition to the strict integrity and checkout checks.
    my %now = map {$_ => 1} split /\n/, capture(git($r, 'rev-list', '--objects', '--all',
        '--reflog',
        '--indexed-objects', '--no-object-names'));
    fail('reachable Git objects changed during cleanup') unless keys(%now) == keys(%reachable)
        && !grep {!$now{$_}} keys %reachable;
    for my $id(keys %bad) {
        my ($ok) = capture_status(git($r, 'cat-file', '-e', $id));
        fail('historical tag was not removed') if $ok
    }
    print "GIT LEGACY TAG CLEANUP PASS; full fsck clean\n";
    return {objects => [sort keys %bad],
        policy => 'fresh clone only; unreachable historical tags; full fsck clean'};
}
# DXSpider cluster.pl derives version/build from an annotated Git tag.
# --no-tags is useful for rejecting legacy objects, but a tagless checkout
# is not a runnable revision of that code. Never manufacture a version tag.
sub needs_version_tags {
    my ($r) = @_;
    return -f "$r/perl/cluster.pl"
        && read_file("$r/perl/cluster.pl") =~  /\bgit\s+--git-dir=\$root\/\.git\s+describe\s+--long\b/;
}

sub version_identity {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {version_identity(@args)});
    }
    my ($r) = @_;
    return undef unless needs_version_tags($r);
    my ($ok, $desc) = capture_status(git($r, 'describe', '--long'));
    chomp $desc;
    fail('DXSpider requires a valid annotated numeric Git version tag') unless $ok
        && $desc =~  /\A\d+(?:\.\d+)*-\d+-g([0-9a-f]+)\z/;
    my $abbrev = $1;
    fail('Git describe does not identify HEAD') unless index(git_value($r, 'rev-parse', 'HEAD'),
        $abbrev) == 0;
    return {describe => $desc, refs_sha => sha256_hex(capture(git($r, 'for-each-ref',
        '--format=%(refname) %(objectname)', 'refs/tags')))};
}

sub version_tag_refs {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return @{owner_file_call(sub {[version_tag_refs(@args)]})};
    }
    my ($url) = @_;
    my $out = capture('timeout', '90', as_owner('git', 'ls-remote', '--tags', '--', $url));
    my (%ref, %peeled);
    for my $line(split /\n/, $out) {
        fail('invalid remote tag advertisement')
            unless $line =~  /\A([0-9a-f]{40,64})\t(refs\/tags\/.+?)(\^\{\})?\z/;
        my ($id, $name, $p) = ($1, $2, $3);
        my $h = $p?\%peeled:\%ref;
        fail('duplicate remote tag advertisement') if exists $h->{$name};
        $h->{$name} = $id;
    }
    fail('orphan peeled tag advertisement') if grep {!exists $ref{$_}} keys %peeled;
    return(\%ref, \%peeled);
}

sub import_version_tags {
    my ($r, $url) = @_;
    return undef unless needs_version_tags($r);
    my ($refs, $peeled) = version_tag_refs($url);
    my (@fetch, @excluded);
    my %ancestors = map {$_ => 1} split /\n/, capture(git($r, 'rev-list', 'HEAD'));

    # Only annotated tags that point into the selected branch history matter to
    # git describe. Lightweight tags are not used by its default invocation.
    # The exact already-audited malformed tag objects are not imported; no refs
    # or objects on the upstream repository are ever changed.

    for my $name(sort keys %$peeled) {
        my $id = $refs->{$name};
        my $target = $peeled->{$name};
        next unless $ancestors{$target};
        if (legacy_tag_known($id)) {
            fail('known malformed historical tag advertised by non-primary source')
                unless $url eq $remote[0];
            print "GIT VERSION TAG EXCLUDED known malformed object $id $name\n";
            push @excluded, $name;
            next
        }
        run(git($r, 'check-ref-format', $name));
        push @fetch, $name;
    }
    fail('no valid annotated version tag advertised on branch history') unless @fetch;
    my @pending = @fetch;
    while (@pending) {
        my @batch = splice(@pending, 0, 32);
        run(git($r, 'fetch', '--no-tags', '--', $url, map {"$_:$_"} @batch));
    }
    for my $name(@fetch) {
        fail('version tag changed during fetch') unless git_value($r, 'rev-parse',
            $name) eq $refs->{$name} && git_value($r, 'cat-file', '-t', $name) eq 'tag'
            && git_value($r,
            'rev-parse', "$name^{}") eq $peeled->{$name};
    }
    my ($after, $after_peeled) = version_tag_refs($url);
    fail('remote annotated tag advertisement changed during import') unless $json->encode([$refs,
        $peeled]) eq $json->encode([$after, $after_peeled]);
    my $v = version_identity($r);
    # Do not silently use an older valid tag if an omitted malformed tag could
    # provide the same or a closer version description. Fall back or block.
    my ($distance) = $v->{describe} =~  /-(\d+)-g[0-9a-f]+\z/;
    for my $name(@excluded) {
        my $d = git_value($r, 'rev-list', '--count', "$peeled->{$name}..HEAD");
        fail('excluded malformed tag could affect DXSpider build; refusing inferred version')
            unless $d =~ /\A\d+\z/ && $d>$distance;
    }
    $j->{git_version_remote_sha} = sha256_hex($json->encode([$refs, $peeled])) if ref($j) eq 'HASH';
    print "GIT VERSION PASS $v->{describe}; ", scalar(@fetch), " annotated tags imported\n";
    return $v;
}

sub clean_git {
    my ($r, $head, $br, $url, $fresh) = @_;
    fail('unsafe git directory') unless -d "$r/.git" && !-l "$r/.git";
    fail('wrong checkout root') unless git_value($r, 'rev-parse', '--show-toplevel') eq $r;
    fail('wrong HEAD/branch') unless git_value($r, 'rev-parse', 'HEAD') eq $head && git_value($r,
        'symbolic-ref', '--short', 'HEAD') eq $br;
    fail('wrong remote provenance') unless git_value($r, 'config', '--get',
        'remote.origin.url') eq $url
        && git_value($r, 'rev-parse', "refs/remotes/origin/$br") eq $head;
    fail('external Git object store') if exists_path("$r/.git/objects/info/alternates");
    fail('dirty candidate') unless capture(git($r, 'status', '--porcelain=v1', '-z',
        '--untracked-files=all', '--ignored=matching')) eq '';
    return repair_legacy_tags($r, $url) if $fresh && $url eq $remote[0];
    run(git($r, 'fsck', '--full', '--no-dangling'));
    return undef;
}
# Git's ignored-directory reporting can escape pathspec exclusions. Filter
# NUL-delimited records ourselves; disable rename collapsing so moves crossing
# a persistence boundary still expose the nonpersistent side.
sub local_changes {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {local_changes(@args)});
    }
    my ($r) = @_;
    return 'NO_GIT' unless -d "$r/.git" && !-l "$r/.git";
    my $s = capture(git($r, 'status', '--porcelain=v1', '-z', '--no-renames',
        '--untracked-files=all',
        '--ignored=matching'));
    my @out;
    for my $rec (split /\0/, $s) {
        fail('invalid porcelain status') unless $rec =~ /\A.. (.+)\z/s;
        my $p = $1;
        next if grep {under($p, $_) || $p eq "$_/"} @persistent;
        push @out, $rec;
    }
    return @out?join("\0", @out)."\0":'';
}

sub local_fingerprint {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {local_fingerprint(@args)});
    }
    my ($r, $dirty) = @_;
    my $head = $dirty eq 'NO_GIT'?'NO_GIT':git_value($r, 'rev-parse', 'HEAD');
    # A porcelain status alone cannot detect a second edit to the same file.
    # Hash the actual nonpersistent tree, not just the list of paths, when dirty.
    my $content = '';
    if (length $dirty) {
        opendir my $dh, $r or fail('open original root');
        my %exclude = map {$_ => 1} ('.', '..', '.git', @persistent);
        my @parts = sort grep {!$exclude{$_}} readdir $dh;
        closedir $dh;
        $content = manifest($r, @parts) if @parts;
    }
    return sha256_hex(join("\0", $head, $dirty, $content));
}

sub remote_head {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {remote_head(@args)});
    }
    my ($url, $br) = @_;
    my ($ok, $s) = capture_status('timeout', '90', as_owner('git', 'ls-remote', '--exit-code', $url,
        "refs/heads/$br"));
    return $ok && $s =~  /\A([0-9a-f]{40,64})\trefs\/heads\/\Q$br\E\n?\z/ ? $1 : undef;
}

sub source_urls {
    return $fixture?("$base/repo", (-d "$base/mirror"?"$base/mirror":())):@remote;
}

sub revision_status {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {revision_status(@args)});
    }
    my ($r, $primary, $mirror) = @_;
    return 'REMOTE_UNAVAILABLE' unless defined($primary) || defined($mirror);
    return 'MIRROR_ONLY_UNCONFIRMED' unless defined($primary);
    return 'NO_LOCAL_GIT' unless -d "$r/.git" && !-l "$r/.git";
    my ($ok, $top) = capture_status(git($r, 'rev-parse', '--show-toplevel'));
    chomp $top;
    return 'NO_LOCAL_GIT' unless $ok && $top eq $r;
    my ($bok, $br) = capture_status(git($r, 'symbolic-ref', '--quiet', '--short', 'HEAD'));
    chomp $br;
    return 'BRANCH_CHANGE' unless $bok && $br eq $branch;
    return 'REVISION_DIFFERS' unless git_value($r, 'rev-parse', 'HEAD') eq $primary;
    if (needs_version_tags($r)) {
        my $ok = eval{
            version_identity($r);
            1
        };
        return 'VERSION_METADATA_MISSING' unless $ok;
    }
    return 'UP_TO_DATE';
}

sub stage_git {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        my $result = owner_file_call(sub {
            stage_git(@args);
            return {map {$_ => $j->{$_}} qw(
                remote head primary_url primary_head new_id git_legacy_cleanup
                git_version_metadata git_version_remote_sha
            )};
        });
        fail('invalid Git worker result') unless ref($result) eq 'HASH';
        for my $key (qw(
            remote head primary_url primary_head new_id git_legacy_cleanup git_version_metadata
            git_version_remote_sha
        )) {
            $j->{$key} = $result->{$key};
        }
        return;
    }
    my ($retry_capacity) = @_;
    my @urls = source_urls();
    my $k = 0;
    my $primary_head;
    for my $url (@urls) {
        ++$k;
        ui_event("Checking source $url");
        my $head = remote_head($url, $branch);
        next unless $head;
        $primary_head = $head if $k == 1;
        if ($k>1 && defined($primary_head) && $head ne $primary_head) {
            print "MIRROR BLOCK: differs from observed primary HEAD\n";
            next
        }
        if ($k>1) { $retry_capacity ? $retry_capacity->() : capacity(1);
        } # failed primary consumes disk
        my $download = "$work/download-$k";
        mkdir($download, 0700) or fail('download directory');
        chown($owner, $group, $download) == 1 or fail('download owner');
        my $dest = "$download/tree";
        my $repair;
        my $ok = eval {
            delete @{$j}{qw(git_version_metadata git_version_remote_sha)};
            ui_event("Downloading branch $branch from $url");
            my $mask = umask 0022;
            my $cloned = eval{
                run('timeout', '600', as_owner('git', 'clone', '--no-tags', '--single-branch',
                    '--no-hardlinks', '--branch', $branch, '--', $url, $dest));
                1
            };
            my $err = $@;
            umask $mask;
            die $err unless $cloned;
            ui_event("Checking Git object integrity and version tags");
            $repair = clean_git($dest, $head, $branch, $url, 1);
            my $version_meta = import_version_tags($dest, $url);
            if ($version_meta) {
                my $second = clean_git($dest, $head, $branch, $url, 1);
                $repair = $second if $second;
                fail('version metadata changed during integrity check')
                    unless $json->encode(version_identity($dest)) eq $json->encode($version_meta);
                $j->{git_version_metadata} = $version_meta;
            }
            clean_git($dest, $head, $branch, $url) if $repair || $version_meta;
            fail('remote changed') unless same(remote_head($url, $branch), $head);
            fail('missing required code') unless -f "$dest/perl/cluster.pl" && !-l "$dest/perl"
                && !-l "$dest/perl/cluster.pl" && -d "$dest/data" && !-l "$dest/data"
                && length(capture(git($dest, 'ls-files', '-z', '--', 'data')));
            1
        };
        if (!$ok) {
            ui_event("Source failed; checking permitted fallback (details in log)");
            print "SOURCE FAILED: $url: $@";
            next
        }
        move_tree($dest, "$work/candidate");
        $j->{remote} = $url;
        $j->{head} = $head;
        $j->{primary_url} = $urls[0];
        $j->{primary_head} = $primary_head;
        $j->{new_id} = ident("$work/candidate");
        $j->{git_legacy_cleanup} = $repair if $repair;
        return;
    }
    fail('no verified remote candidate; partial downloads retained');
}

# tar is an unambiguous, deterministic byte stream: SHA-256 includes path,
# content, uid/gid, mode, nanosecond mtime, symlink target, hardlink topology,
# ACL and xattrs. No archive written. atime/ctime are not copy invariants.

# ==========================================================================
# 04. Persistent data, backup and SQLite validation
# ==========================================================================

sub manifest {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {manifest(@args)});
    }
    my ($r, @parts) = @_;
    my $filtered = (@parts && $parts[0] eq ':backup')?shift(@parts):0;
    my $prune = $filtered?backup_prune($r):undef;
    my %links;
    my $dev = (stat($r))[0];
    for my $part (@parts) {
        walk("$r/$part", sub {
            my ($p, $s) = @_;
            if (!S_ISDIR($s->[2]) && $s->[3]>1) {
                my $k = "$s->[0]:$s->[1]";
                $links{$k}[0]++;
                $links{$k}[1] = $s->[3]
            }
        }, $dev, undef, $prune)
    }

    # A filtered backup may intentionally omit another name of a hardlink.
    # The full rollback and persistence manifests still reject external links.
    if (!$filtered) {
        for my $k(keys %links) {
            fail('hardlink outside copied tree') unless $links{$k}[0] == $links{$k}[1]
        }
    }
    my @filters = $filtered?('--anchored', map {"--exclude=./$_/*"} @backup_empty):();
    my @c = ('tar', '--format=pax', '--sort=name', '--numeric-owner', '--acls', '--xattrs',
        '--xattrs-include=*', '--selinux',
        '--pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime', @filters, '-C', $r,
        '-cf', '-', '--', @parts);
    open my $h, '-|', @c or fail('tar pipe');
    binmode $h;
    my $d = Digest::SHA->new(256);
    $d->addfile($h);
    close $h or fail('tar manifest failed');
    return $d->hexdigest;
}

sub copy_backup {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {copy_backup(@args)});
    }
    my ($src, $dst) = @_;
    my $sha = manifest($src, ':backup', '.');
    fail('backup target already exists') if exists_path($dst);
    mkdir($dst, 0700) or fail("backup mkdir $dst: $!");
    run('rsync', '-aHAX', '--numeric-ids', '--modify-window=-1', backup_filters(), '--', "$src/",
        "$dst/");
    for my $p (@backup_empty) {
        my $d = "$dst/$p";
        next unless -d $d && !-l $d;
        opendir my $dh, $d or fail("backup dir $d: $!");
        my @children = grep {$_ ne '.' && $_ ne '..'} readdir $dh;
        closedir $dh;
        fail("excluded backup contents present: $p") if @children;
    }
    fail('backup mismatch') unless manifest($dst, ':backup', '.') eq $sha && manifest($src,
        ':backup',
        '.') eq $sha;
    my $diff = capture('rsync', '-aHAXnic', '--numeric-ids', '--modify-window=-1', '--delete',
        backup_filters(), '--', "$src/", "$dst/");
    fail("backup metadata mismatch: $diff") if length $diff;
    return $sha;
}

sub remove_candidate_part {
    my ($p) = @_;
    if (-l $p || (-e $p && !-d $p)) {
        unlink $p or fail("unlink $p: $!")
    }  elsif (-d $p) {
        my $err;
        remove_tree($p, {safe => 1, error => \$err});
        fail("remove $p failed") if @$err || exists_path($p)
    }
}

sub copy_persistent {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {copy_persistent(@args)});
    }
    my ($a, $b) = @_;
    my $before = manifest($a, @persistent);
    for my $p (@persistent) {
        fail("unsafe source $p") unless -d "$a/$p" && !-l "$a/$p";
        remove_candidate_part("$b/$p")
    }
    inject('copy');
    run('cp', '-a', '--preserve=all', '--', map("$a/$_", @persistent), $b);
    my $after = manifest($a, @persistent);
    my $new = manifest($b, @persistent);
    fail('persistent SHA-256 mismatch') unless $before eq $after && $after eq $new;
    # Independent rsync metadata/content comparison; -R preserves relative paths
    # across the six roots, and -H validates hardlinks within the copy set.
    my $diff = capture('rsync', '-aHAXRnic', '--modify-window=-1', '--delete', '--', map("$a/./$_",
        @persistent), "$b/");
    fail("metadata or content mismatch: $diff") if length $diff;
    return $new;
}

sub sqlite_engine {
    return 'cli' if find_tool('sqlite3');
    my ($ok) = capture_status($^X, '-e',
        'exit(eval { require DBI; require DBD::SQLite; 1 } ? 0 : 1)');
    return $ok?'dbi':'';
}

sub sqlite_check {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {sqlite_check(@args)});
    }
    my ($tree) = @_;
    my @db = @{inventory_sizes($tree, 1, 1, @persistent)->{dbs}};
    return print "SQLITE: no database signatures found\n" unless @db;
    my $engine = sqlite_engine();
    if (!$engine) {
        print "SQLITE: ".scalar(@db)." database(s); integrity check unavailable (no sqlite3 or DBI/DBD::SQLite)\n";
        fail('SQLite integrity engine unavailable') unless $fixture;
        return
    }
    my $dir = "$work/sqlite-check";
    mkdir($dir, 0700) or fail('SQLite scratch directory');
    my $n = 0;
    for my $db (@db) {
        my $d = "$dir/".(++$n);
        mkdir($d, 0700) or fail('SQLite scratch subdirectory');
        my ($sb, $sn) = (8192, 2);
        my @copy;
        for my $suffix ('', '-wal', '-shm', '-journal') {
            my $p = "$db$suffix";
            next unless exists_path($p);
            my @st = lstat($p);
            fail("unsafe SQLite auxiliary $p") unless @st && S_ISREG($st[2]);
            $sb += entry_bytes(\@st);
            ++$sn;
            push @copy, [$p, "$d/db$suffix"];
        }
        my ($mb, $mn) = capacity_margin($sb, $sn);
        capacity_check($sb+$mb, $sn+$mn, 1);
        run('cp', '-a', '--', @$_) for @copy;
        # Only this disposable copy is opened. WAL/SHM and rollback journals in
        # the original and candidate are never removed or altered by SQLite checks.
        my @cmd = $engine eq 'cli'?('sqlite3', '-batch', '-readonly', "$d/db",
            'PRAGMA integrity_check;'):
        ($^X, '-MDBI', '-MDBD::SQLite', '-e',
            'my $p=shift;my $h=DBI->connect("dbi:SQLite:dbname=$p","","",{RaiseError=>1,PrintError=>0,sqlite_open_flags=>1});my $r=$h->selectcol_arrayref("PRAGMA integrity_check");print join("\n",@$r),"\n";$h->disconnect;', "$d/db");
        my $out = capture('timeout', '900', @cmd);
        fail('SQLite integrity_check failed for '.$json->encode(substr($db, length($tree)+1)))
            unless $out eq "ok\n";
        print 'SQLITE OK ', $json->encode(substr($db, length($tree)+1)), " engine=$engine\n";
        remove_candidate_part($d);
        sync_dir($dir);
    }

    # Successful scratch copies were removed individually; a failed check
    # throws before removal and retains its own scratch for diagnosis.
    rmdir($dir) or fail("remove empty SQLite scratch $dir: $!");
    sync_dir($work);
}

sub sync_tree {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {sync_tree(@args)});
    }
    my ($p) = @_;
    run('sync', '-f', $p);
    sync_dir($p);
}

# ==========================================================================
# 05. Linux process and systemd inventory
# ==========================================================================

sub proc_info {
    my ($pid) = @_;
    return undef unless defined($pid) && $pid =~ /\A[1-9]\d*\z/;
    my $s = optional_read("/proc/$pid/stat");
    return undef unless $s =~ /^\d+ \(.*\) ([A-Z]) (.*)$/s && $1 ne 'Z';
    my @f = split /\s+/, $2;
    return undef unless @f>18;
    my $st = $f[18];
    my @argv = split /\0/, optional_read("/proc/$pid/cmdline");
    my $cwd = readlink("/proc/$pid/cwd")//'';
    my $status = optional_read("/proc/$pid/status");
    my ($ruid, $uid) = $status =~ /^Uid:\s*(\d+)\s+(\d+)/m;
    my ($rgid, $gid) = $status =~ /^Gid:\s*(\d+)\s+(\d+)/m;
    return undef unless defined($uid) && defined($gid);
    my $cg = optional_read("/proc/$pid/cgroup");
    my $again = optional_read("/proc/$pid/stat");
    return undef unless $again =~ /^\d+ \(.*\) ([A-Z]) (.*)$/s && $1 ne 'Z';
    my @again = split /\s+/, $2;
    return undef unless @again>18 && $again[18] eq $st;
    return {pid => 0+$pid, start => $st, cwd => $cwd, uid => 0+$uid, gid => 0+$gid, ruid => 0+$ruid,
        rgid => 0+$rgid, ppid => 0+$f[0], session => 0+$f[2], tty_nr => 0+$f[3], argv => \@argv,
        cgroup => $cg};
}

sub all_pids {
    opendir my $d, '/proc' or fail('cannot inspect proc');
    my @p = grep {/^[1-9]\d*$/} readdir $d;
    closedir $d;
    return @p
}

sub process_references {
    my ($p, @trees) = @_;
    my $pid = $p->{pid};
    my $matches = sub{
        my ($v) = @_;
        $v =~ s/ \(deleted\)$//;
        return scalar grep {under($v, $_)} @trees
    };
    return 'cwd' if $matches->($p->{cwd});
    return 'argv' if grep {$matches->($_)} @{$p->{argv}};
    my $exe = readlink("/proc/$pid/exe")//'';
    return 'exe' if $matches->($exe);
    if (opendir(my $dh, "/proc/$pid/fd")) {
        my @fds = grep {/^[0-9]+$/} readdir $dh;
        closedir $dh;
        for my $fd (@fds) {
            my $v = readlink("/proc/$pid/fd/$fd")//'';
            return 'open-fd' if $matches->($v)
        }
    } elsif (!$fixture && @{$p->{argv}}) {
        my $now = proc_info($pid);
        return 'fd-inspection-unavailable' if $now && $now->{start} eq $p->{start}
    }
    # mmap can keep a SQLite database open without an ordinary descriptor.
    for my $line (split /\n/, optional_read("/proc/$pid/maps")) {
        my @f = split /\s+/, $line, 6;
        return 'mapping' if @f == 6 && $matches->($f[5])
    }
    return '';
}

sub unknown_writers {
    my ($known, @trees) = @_;
    my @out;
    for my $pid (all_pids()) {
        next if $pid == $$;
        my $p = proc_info($pid) or next;
        next if defined($known->{$pid}) && $known->{$pid} eq $p->{start};
        my $why = process_references($p, @trees);
        push @out, [$pid, $why] if $why
    }
    return @out;
}

sub require_no_unknown_writers {
    my ($known, @trees) = @_;
    my @p = unknown_writers($known, @trees);
    fail('unmanaged/unknown process references installation: '.join(',',
        map {"$_->[0]:$_->[1]"} @p))
        if @p
}

sub unit_info {
    my ($r, $name) = @_;
    my $u = $name//$units{$r};
    my ($ok, $out) = capture_status('timeout', '10', 'systemctl', 'show', $u, '--no-pager',
        '--property=Id,LoadState,ActiveState,SubState,MainPID,ControlGroup,FragmentPath,ExecStart,WorkingDirectory,User,Group,NeedDaemonReload,KillMode,InvocationID,Type,Result,ActiveEnterTimestampMonotonic');
    my %h = map {split /=/, $_, 2} grep {/=/} split /\n/, $out;
    # A missing unit may produce a nonzero status on some systemd releases.
    # Accept only explicit, complete not-found/inactive/zero-PID evidence.
    $h{ok} = ($ok || (($h{LoadState}//'') eq 'not-found' && ($h{ActiveState}//'') eq 'inactive'
        && defined($h{MainPID}) && $h{MainPID} eq '0'))?1:0;
    $h{name} = $u;
    # systemd aliases have the same canonical Id and cgroup. Do not treat
    # aliases as different service processes or stop a guessed name.
    $h{name} = $h{Id} if ($h{Id}//'') =~  /\A[A-Za-z0-9_][A-Za-z0-9_.@-]*\.service\z/;
    my $pid = $h{MainPID}//0;
    my $p = proc_info($pid);
    my $cg = $h{ControlGroup}//'';
    my $assoc = under($h{WorkingDirectory}//'', $root)
        || ($h{ExecStart}//'') =~  /(?:^|[\s=;])\Q$root\E\//;
    # The reference installer uses /spider as an alias to the physical tree.
    # Resolve that exact alias, not an arbitrary text match or another node.
    if (!$assoc && ((realpath('/spider')//'') eq $root || ($j && ($j->{state}//'') eq 'ROLLING_BACK'
        && !exists_path($root) && -l '/spider' && (readlink('/spider')//'') eq $root))) {
        $assoc=under($h{WorkingDirectory}//'', '/spider') || ($h{ExecStart}//'') =~ m{(?:^|[\s=;])/spider/};
    }
    $h{associated} = $assoc?1:0;
    my $uid_ok = 0;
    my $gid_ok = 0;
    if ($p) {
        my $u = $h{User} || 'root';
        my @pw = getpwnam($u);
        @pw = getpwuid($u) if $u =~ /^\d+$/;
        my $uid = $u =~ /^\d+$/?0+$u:$pw[2];
        my $g = $h{Group}//'';
        my $gid = length($g)?($g =~ /^\d+$/?0+$g:(getgrnam($g))[2]):$pw[3];
        $uid_ok = defined($uid) && $uid == $p->{uid};
        $gid_ok = defined($gid) && $gid == $p->{gid};
    }
    my $alias = (realpath('/spider')//'') eq $root;
    my $process_assoc = $p && (under($p->{cwd}, $root) || grep {under($_, $root) || ($alias
        && under($_, '/spider'))} @{$p->{argv}});
    $h{confirmed} = (
        $assoc && $p && $uid_ok && $gid_ok && $process_assoc
        && ($h{SubState}//'') eq 'running'
        && length($cg)
        && $p->{cgroup} =~ /(?:^|\n)[^\n]*?:\Q$cg\E(?:\n|\/|$)/
        && $cg =~ m{/\Q$h{name}\E$}
    ) ? 1 : 0;
    $h{pid_start} = $p->{start} if $p;
    if (($h{LoadState}//'') eq 'loaded') {
        my ($c, $raw) = capture_status('timeout', '10', 'systemctl', 'cat', $u, '--no-pager');
        $h{unit_sha} = sha256_hex($raw) if $c && length $raw;
    }
    return \%h;
}

# Discover named units independent of their filenames. Only direct invocations
# of the three upstream entry points are recognized; wrappers are never guessed.

sub service_entry_points {
    my ($v) = @_;
    my $exec = $v->{ExecStart}//'';
    # systemctl show represents ExecStart as a record containing path and
    # argv[]. Recognize only one record with a direct script or Perl exec.
    # Never classify an echo, shell wrapper, argument reference, or hook.
    return () unless $exec =~  /\A\{\s*path=(\S+)\s*;\s*argv\[\]=(.*?)\s*;[^{}]*\}\s*\z/;
    my ($path, $argv) = ($1, $2);
    my @args = split /\s+/, $argv;
    return () unless @args && $args[0] eq $path;
    my $entry;
    if ($path =~ m{\A/(?:usr/)?bin/perl(?:[0-9.]+)?\z}) {
        shift @args;
        shift @args if @args && $args[0] eq '-w';
        return () unless @args == 1;
        $entry = $args[0];
    } else {
        return () unless @args == 1;
        $entry = $path;
    }
    return () unless $entry =~ m{\A(/[A-Za-z0-9_./-]+?)/(perl/cluster\.pl|dxweb/start\.pl|dxweb-admin/admin\.pl)\z};
    my ($tree, $rel) = ($1, $2);
    return () if $tree =~ m{(?:^|/)\.\.?(/|$)|//};
    my $r = $rel eq 'perl/cluster.pl'?'spider':$rel eq 'dxweb/start.pl'?'web':'admin';
    return ([$tree, $r]);
}

# An unclassified unit that refers to a selected tree is a blocker, not a
# candidate for automatic control. This includes shell wrappers and arguments.

sub service_references_tree {
    my ($v) = @_;
    my $cwd = $v->{WorkingDirectory}//'';
    my @trees = ($root);
    push @trees, '/spider' if (realpath('/spider')//'') eq $root;
    for my $tree (@trees) {
        return 1 if under($cwd,$tree) || ($v->{ExecStart}//'') =~ m{(?:^|[\s=;"'])\Q$tree\E(?:/|[\s;"']|$)};
    }
    return 0;
}

sub service_catalogue {
    my %names;
    my ($files_ok, $files) = capture_status('timeout', '15', 'systemctl', 'list-unit-files',
        '--type=service', '--no-legend', '--no-pager');
    my ($loaded_ok, $loaded) = capture_status('timeout', '15', 'systemctl', 'list-units', '--all',
        '--type=service', '--plain', '--no-legend', '--no-pager');
    return (0, []) unless $files_ok && $loaded_ok;
    for my $line (split /\n/, $files."\n".$loaded) {
        my ($n) = $line =~  /^\s*([A-Za-z0-9_][A-Za-z0-9_.@-]*\.service)\s/;
        next unless defined($n) && $n !~ /@\.service$/;
        $names{$n} = 1;
    }
    my @names = sort keys %names;
    my @records;
    while (@names) {
        my @batch = splice(@names, 0, 40);
        my ($ok, $raw) = capture_status('timeout', '30', 'systemctl', 'show', '--no-pager',
            '--property=Id,Names,LoadState,ExecStart,WorkingDirectory', @batch);
        # Unknown/masked units can make show exit nonzero. Require an explicit
        # record for each requested name, or block instead of missing a writer.
        my %ids;
        for my $block (split /\n\s*\n/, $raw) {
            my %v = map {split /=/, $_, 2} grep {/=/} split /\n/, $block;
            next unless ($v{Id}//'') =~  /\A[A-Za-z0-9_][A-Za-z0-9_.@-]*\.service\z/;
            $ids{$_} = 1 for ($v{Id}, split /\s+/, $v{Names}//'');
            push @records, \%v if ($v{LoadState}//'') eq 'loaded';
        }
        # Aliases may resolve to a different Id. A successful show is required
        # in live mode; not-found/masked entries must not be acted on.
        return (0, []) if grep {!$ids{$_}} @batch;
    }
    return (1, \@records);
}

sub selected_service_role {
    my ($v) = @_;
    my %r;
    for my $m (service_entry_points($v)) {
        my ($tree, $role) = @$m;
        next unless $tree eq $root || (realpath($tree)//'') eq $root;
        $r{$role} = 1;
    }
    return keys(%r) == 1?(keys %r)[0]:undef;
}

sub resolve_service_inventory {
    my ($catalogue, $standard) = @_;
    my %u = %$standard;
    my @block;
    my %seen;
    for my $v (@$catalogue) {
        my $name = $v->{Id};
        next if $seen{$name}++;
        next if grep {($_->{name}//'') eq $name && ($_->{LoadState}//'') eq 'loaded'} values %u;
        my $r = selected_service_role($v);
        if (!defined $r) {
            # WorkingDirectory alone cannot identify the role of a wrapper.
            if (service_references_tree($v)) {
                push @block, "Unrecognized associated unit: $name";
            }
            next;
        }
        my $actual = unit_info($r, $name);
        if (!unit_definition_ok($actual) || (selected_service_role($actual)//'') ne $r) {
            push @block, "Unverified custom unit: $name";
            next;
        }
        if (($u{$r}{LoadState}//'') ne 'not-found') {
            push @block, "Multiple or conflicting units for $r: $u{$r}{name}, $name";
            next;
        }
        $u{$r} = $actual;
    }
    return (\%u, \@block);
}

sub service_inventory {
    my %standard = map {$_ => unit_info($_)} @stop;
    return (\%standard, []) if $systemd_fixture;
    my ($ok, $records) = service_catalogue();
    return (\%standard, LIVE_ENABLED?['Complete systemd inventory unavailable']:[]) unless $ok;
    # Preserve the previously validated contract for the three standard
    # unit names. Custom units additionally require the direct entry point.
    return resolve_service_inventory($records, \%standard);
}

sub transaction_unit_name {
    my ($r) = @_;
    my $name = ($j && $j->{services} && $j->{services}{$r})?$j->{services}{$r}{unit_name}:undef;
    $name = $units{$r} unless defined $name;
    fail('invalid journal unit name') unless $name =~  /\A[A-Za-z0-9_][A-Za-z0-9_.@-]*\.service\z/;
    return $name;
}

sub known_unit_processes {
    my ($u) = @_;
    my %known;
    for my $pid (all_pids()) {
        my $p = proc_info($pid) or next;
        for my $v (values %$u) {
            next unless $v->{confirmed};
            my $cg = $v->{ControlGroup};
            if ($p->{cgroup} =~ /(?:^|\n)[^\n]*?:\Q$cg\E(?:\/|\n|$)/) {
                $known{$pid} = $p->{start};
                last
            }
        }
    }
    return \%known;
}

sub unit_definition_ok {
    my ($v) = @_;
    return $v->{ok} && ($v->{LoadState}//'') eq 'loaded' && $v->{associated} && $v->{unit_sha}
    && ($v->{NeedDaemonReload}//'') eq 'no'
        && ($v->{KillMode}//'') =~  /\A(?:control-group|mixed)\z/;
}

sub unit_members {
    my ($v) = @_;
    my %p;
    my $cg = $v->{ControlGroup}//'';
    my $name = $v->{name}//'';
    fail('invalid service name for cgroup inspection')
        unless $name =~  /\A[A-Za-z0-9_.@-]+\.service\z/;
    my $exact=$cg =~ m{^/(?:[^/]+/)*\Q$name\E$};
    # systemctl may omit ControlGroup once stopped. Look for the exact unit
    # component in every visible cgroup rather than treating an empty value as proof.
    for my $pid (all_pids()) {
        my $q = proc_info($pid) or next;
        my $matches = $exact ? ($q->{cgroup} =~ /(?:^|\n)[^\n]*?:\Q$cg\E(?:\n|\/|$)/) : ($q->{cgroup} =~ /(?:^|\n)[^\n]*?:\/(?:[^\/\n]+\/)*\Q$name\E(?:\n|\/|$)/);
        $p{$pid} = $q->{start} if $matches;
    }
    return \%p;
}

sub unit_stopped {
    my ($v) = @_;
    return (($v->{ActiveState}//'') =~  /\A(?:inactive|failed)\z/ && !($v->{MainPID}//0)
        && !keys %{unit_members($v)})?1:0;
}

sub unit_identity {
    my ($v) = @_;
    return join(':',
        map {$v->{$_}//''} qw(MainPID pid_start InvocationID ActiveEnterTimestampMonotonic));
}

sub host_inventory {
    my %u = map {$_ => unit_info($_)} @stop;
    my $blocked = 0;
    for my $r (@stop) {
        my $v = $u{$r};
        printf "UNIT %s load=%s active=%s pid=%s associated=%d identity=%s\n", $v->{name},
            $v->{LoadState}//'unknown', $v->{ActiveState}//'unknown', $v->{MainPID}//0,
            $v->{associated}, $v->{confirmed}?'CONFIRMED':'NOT_CONFIRMED';
        $blocked = 1 unless ($v->{LoadState}//'') eq 'not-found' || (unit_definition_ok($v)
            && ((($v->{ActiveState}//'') eq 'inactive' && unit_stopped($v))
            || (($v->{ActiveState}//'') eq 'active' && $v->{confirmed})));
    }
    my $known = known_unit_processes(\%u);
    for my $q (unknown_writers($known, $root)) {
        my $p = proc_info($q->[0]) or next;
        my $kind = manual_cluster($p);
        printf "%s pid=%s start=%s uid=%s gid=%s reason=%s argc=%d cwd=%s (argv omitted)\n",
            $kind?'MANUAL DXSPIDER':manual_candidate($p)?'MANUAL DXSPIDER CANDIDATE':'UNMANAGED',
            @$p{qw(pid start uid gid)}, $q->[1], scalar(@{$p->{argv}}), under($p->{cwd},
            $root)?$json->encode($p->{cwd}):'(outside installation)';
        $blocked = 1
    }
    print "MANUAL/UNKNOWN RESTART: requires verified plan; production disabled\n" if $blocked;
    return($blocked, \%u);
}

# Read only Linux socket ownership. /proc/net/tcp uses host-endian words.

# ==========================================================================
# 06. TCP listeners, manual identity and service probes
# ==========================================================================

sub tcp_listeners {
    my @out;
    for my $family (4, 6) {
        my $path = $family == 4?'/proc/net/tcp':'/proc/net/tcp6';
        next if $family == 6 && !-e $path;
        for my $line (split /\n/, read_file($path)) {
            $line =~ s/^\s+//;
            my @f = split /\s+/, $line;
            next unless @f >= 10 && $f[3] eq '0A' && $f[1] =~ /\A([0-9A-Fa-f]+):([0-9A-Fa-f]{4})\z/
                && $f[9] =~ /\A[1-9]\d*\z/;
            my ($raw, $port) = split /:/, $f[1];
            next unless length($raw) == ($family == 4?8:32);
            my $packed = pack('L*', map {hex($_)} $raw =~ /(.{8})/g);
            my $addr = inet_ntop($family == 4?AF_INET:AF_INET6, $packed);
            push @out, {family => $family, address => $addr, port => hex($port), inode => $f[9]}
                if defined $addr;
        }
    }
    return @out;
}

sub listener_owners {
    my ($known) = @_;
    my %owned;
    my $net = readlink('/proc/self/ns/net')//'';
    fail('cannot identify network namespace') unless length $net;
    for my $pid (keys %$known) {
        my $p = proc_info($pid) or next;
        next unless $p->{start} eq $known->{$pid};
        next unless (readlink("/proc/$pid/ns/net")//'') eq $net;
        opendir my $d, "/proc/$pid/fd" or next;
        my @fd = grep {/^[0-9]+$/} readdir $d;
        closedir $d;
        my %s;
        for my $fd (@fd) {
            my $v = readlink("/proc/$pid/fd/$fd")//'';
            $s{$1} = 1 if $v =~ /\Asocket:\[([0-9]+)\]\z/
        }
        my $now = proc_info($pid);
        next unless $now && $now->{start} eq $p->{start};
        push @{$owned{$_}}, 0+$pid for keys %s;
    }
    return \%owned;
}

sub loopback_candidate {
    my ($l, $port) = @_;
    return $l->{port} == $port && ($l->{address} eq '127.0.0.1' || $l->{address} eq '0.0.0.0'
        || $l->{address} eq '::' || $l->{address} eq '::ffff:127.0.0.1'
        || $l->{address} eq '::ffff:0.0.0.0');
}

sub require_listener {
    my ($r, $port, $known) = @_;
    my @l = grep {loopback_candidate($_, $port)} tcp_listeners();
    my $owned = listener_owners($known);
    fail("no loopback listener for $r port $port") unless @l;
    fail("listener not owned by expected process set: $r port $port")
        if grep {!$owned->{$_->{inode}}} @l;
    # Detect observed shared descriptors, e.g. sockets passed to another unit.
    # The inspection is a snapshot, not a guarantee against future descriptor passing.
    my %others;
    for my $pid (all_pids()) {
        next if exists $known->{$pid};
        my $p = proc_info($pid) or next;
        $others{$pid} = $p->{start}
    }
    my $foreign = listener_owners(\%others);
    fail("listener also held by another process: $r port $port")
        if grep {$foreign->{$_->{inode}}} @l;
    return join(',', sort map {$_->{inode}} @l);
}

sub manual_candidate {
    my ($p) = @_;
    my @a = @{$p->{argv}};
    my $exe = readlink("/proc/$p->{pid}/exe")//'';
    return 0 unless @a >= 2 && basename($exe) =~ /\Aperl(?:[0-9.]+)?\z/
        && basename($a[0]) =~ /\Aperl(?:[0-9.]+)?\z/;
    return ($a[-1]=~m{\A(?:[A-Za-z0-9_.-]+/|/)*cluster\.pl\z} && !grep {$_ ne '-w' && $_ ne '-T' && $_ ne '-t'} @a[1..$#a-1])?1:0;
}

sub manual_cluster {
    my ($p) = @_;
    return 0 unless manual_candidate($p);
    # A program may have changed cwd after exec. Failure to resolve a relative
    # argv against the current cwd does NOT prove another installation.
    my $a = $p->{argv}[-1];
    my $resolved=realpath($a=~m{^/}?$a:"$p->{cwd}/$a");
    return defined($resolved) && $resolved eq "$root/perl/cluster.pl" ? 1:0;
}

sub manual_launch_match {
    my ($p) = @_;
    return 0 unless length($manual_launch_dir) && manual_candidate($p);
    return 0 unless $manual_launch_dir eq "$root/perl"
        && (realpath($manual_launch_dir)//'') eq $manual_launch_dir;
    return 0 unless $p->{cwd} eq $root || $p->{cwd} eq $manual_launch_dir;
    return 0 unless $p->{uid} == $owner && $p->{gid} == $group && $p->{ruid} == $p->{uid}
        && $p->{rgid} == $p->{gid};
    my $a = $p->{argv}[-1];
    return 0 unless $a eq './cluster.pl' || $a eq 'cluster.pl' || $a eq "$root/perl/cluster.pl";
    return (realpath($a=~m{^/}?$a:"$manual_launch_dir/$a")//'') eq "$root/perl/cluster.pl";
}

sub manual_probe_identity {
    my ($p) = @_;
    return join("\0", @$p{qw(pid start uid gid ruid rgid cwd)}, @{$p->{argv}},
        readlink("/proc/$p->{pid}/exe")//'');
}

# Discovery only: never echo cookies, headers, full body or environment. The
# observed literal is a proposal for review, not an approved health contract.

sub observe_response {
    my ($type, $port) = @_;
    my $reply = '';
    my $ok = eval{
        local $SIG{ALRM} = sub{
            die "response timeout\n"
        };
        alarm 5;
        my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp',
            Timeout => 3) or die "connect failed\n";
        if ($type eq 'http') {
            print {$sock} "GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n" or die "write failed\n";
        }
        while (length($reply)<65536) {
            my $n = sysread($sock, my $b, 4096);
            die "read failed\n" unless defined $n;
            last unless $n;
            $reply .= $b;
            last if $type eq 'banner' && (index($reply, 'login: ') == 0
                || $reply =~ /[^\r\n]+\r?\n/);
            last if $type eq 'http' && $reply=~m{</title>}i;
        }
        close $sock;
        1;
    };
    alarm 0;
    fail('no usable response') unless $ok || length $reply;
    if ($type eq 'banner' && index($reply, 'login: ') == 0) {
        return {type => 'prompt', port => $port, expect => 'login: '}
    }
    if ($type eq 'banner') {
        my ($line) = $reply =~ /([^\r\n]{1,250})\r?\n/;
        fail('no complete banner line') unless defined($line) && $line !~ /[^\x20-\x7e]/;
        return {type => $type, port => $port, expect => $line};
    }
    my($status)=$reply=~m{\AHTTP/1\.[01] (\d{3})[^\r\n]*\r\n};fail('no valid HTTP status') unless defined $status;
    my $i = index($reply, "\r\n\r\n");
    fail('incomplete HTTP headers') if $i < 0;
    my $body = substr($reply, $i + 4);
    my ($title) = $body =~ m{<title[^>]*>([^<\r\n]{1,200})</title>}i;
    if (defined $title) {
        require Encode;
        my $decoded = eval {
            Encode::decode('UTF-8', $title, Encode::FB_CROAK())
        };
        $title = $decoded if defined $decoded;
    }
    return {type => $type, port => $port, path => '/', status => 0+$status, (defined($title)
        && $title =~ /\A[^\x00-\x1f\x7f]+\z/?(expect => $title):())};
}

sub observe_owned_endpoint {
    my ($r, $type, $port, $known, $check) = @_;
    my $socket = require_listener($r, $port, $known);
    my $obs = observe_response($type, $port);
    $check->();
    fail('listener changed during observation') unless require_listener($r, $port,
        $known) eq $socket;
    return $obs;
}

sub describe_process {
    my ($p) = @_;
    my $comm = optional_read("/proc/$p->{pid}/comm");
    chomp $comm;
    my $status = optional_read("/proc/$p->{pid}/status");
    my ($ppid) = $status =~ /^PPid:\s*(\d+)/m;
    my $parent = defined($ppid)?optional_read("/proc/$ppid/comm"):'';
    chomp $parent;
    print 'PROCESS ', $json->encode({pid => $p->{pid}, start => $p->{start}, uid => $p->{uid},
        gid => $p->{gid}, comm => $comm, ppid => $ppid, parent_comm => $parent,
        session => $p->{session}, tty_nr => $p->{tty_nr}, ruid => $p->{ruid}, rgid => $p->{rgid},
        cwd => under($p->{cwd}, $root)?$p->{cwd}:'outside', argc => scalar @{$p->{argv}},
        manual_cluster => manual_cluster($p)?1:0, manual_candidate => manual_candidate($p)?1:0}),
        "\n";
    # Print exact argv only for a narrow, secret-free Perl invocation of cluster.pl.
    my @a = @{$p->{argv}};
    if (manual_candidate($p)) {
        print 'MANUAL ARGV ', $json->encode(\@a),
            " (observation only; no production authorization)\n";
        my $exe = readlink("/proc/$p->{pid}/exe")//'';
        my %io;
        for my $fd (0..2) {
            my $target = readlink("/proc/$p->{pid}/fd/$fd")//'';
            $io{$fd}=$target=~m{^/dev/(?:pts/\d+|tty\w*|null)$}?$target:$target=~/^pipe:/?'pipe':$target=~/^socket:/?'socket':length($target)?'file/other':'unavailable';
        }
        print 'MANUAL CONTEXT ', $json->encode({exe => $exe, stdio => \%io}),
            " (environment not inspected)\n";
    }
}

sub integration_check {
    fail('root required for complete process inspection') if $> != 0;
    print 'DXSpider Updater ', VERSION,
        " INTEGRATION CHECK (no stop/start or tree mutation)\nINSTALLATION $root\nBRANCH $branch\n";
    my ($blocked, $u) = host_inventory();
    my %role_known;
    my @manual;
    my $known = known_unit_processes($u);
    for my $r (@stop) {
        my $v = $u->{$r};
        print 'UNIT DETAIL ', $json->encode({role => $r,
            map {$_ => $v->{$_}} qw(
                name LoadState ActiveState SubState MainPID ControlGroup FragmentPath
                WorkingDirectory User Group NeedDaemonReload KillMode Type Result InvocationID
                unit_sha
            )}), "\n";
        $role_known{$r} = unit_members($v) if $v->{confirmed};
    }
    for my $q (unknown_writers($known, $root)) {
        my $p = proc_info($q->[0]) or next;
        describe_process($p);
        if (manual_candidate($p)) {
            my $r = manual_cluster($p)?'manual':'manual_candidate';
            $role_known{$r}{$p->{pid}} = $p->{start};
            push @manual, $p if manual_launch_match($p)
        }
    }
    my @l = tcp_listeners();
    for my $r (sort keys %role_known) {
        my $owned = listener_owners($role_known{$r});
        for my $l (@l) {
            next unless $owned->{$l->{inode}};
            print 'LISTENER ', $json->encode({role => $r, %$l, pids => $owned->{$l->{inode}}}), "\n"
        }
    }
    if (length $manual_launch_dir) {
        path_check($manual_launch_dir);
        fail('manual launch directory must be canonical installation/perl')
            unless $manual_launch_dir eq "$root/perl"
            && (realpath($manual_launch_dir)//'') eq $manual_launch_dir;
        print 'MANUAL LAUNCH MATCHES ', scalar(@manual),
            " (operator-provided launch directory; no signal/restart permission)\n";
    }
    my %ports = (spider => $spider_port, web => $web_port, admin => $admin_port);
    for my $r (@start) {
        next unless $ports{$r};
        my $ok = eval{
            my ($known, $check);
            my $v = $u->{$r};
            if ($v->{confirmed} && unit_definition_ok($v)) {
                $known = unit_members($v);
                $check = sub{
                    my $a = unit_info($r);
                    fail('unit changed during observation') unless $a->{confirmed}
                        && unit_definition_ok($a) && same($a->{unit_sha}, $v->{unit_sha})
                        && unit_identity($a) eq unit_identity($v)
                };
            }
            elsif ($r eq 'spider' && @manual == 1
                && ($v->{LoadState}//'') =~ /\A(?:loaded|not-found)\z/
                && ($v->{ActiveState}//'') eq 'inactive' && unit_stopped($v)) {
                my $p = $manual[0];
                my $id = manual_probe_identity($p);
                $known = {$p->{pid} => $p->{start}};
                $check = sub{
                    my $a = proc_info($p->{pid});
                    fail('manual process changed during observation') unless $a
                        && manual_launch_match($a) && manual_probe_identity($a) eq $id
                };
            }
            else {
                fail('no unique verified endpoint owner')
            }
            my $obs = observe_owned_endpoint($r, $r eq 'spider'?'banner':'http', $ports{$r}, $known,
                $check);
            print 'PROBE OBSERVATION ', $json->encode({role => $r, %$obs}), " (review required)\n";
            1;
        };
        print "PROBE OBSERVATION $r BLOCK: $@" unless $ok;
    }
    my $d = local_changes($root);
    if ($d eq 'NO_GIT') {
        print "LOCAL CHANGES NO_GIT\n"
    } else {
        print 'LOCAL CHANGES ', $json->encode([split /\0/, $d]), "\n";
        print 'LOCAL HEAD ', git_value($root, 'rev-parse', 'HEAD'), "\n";
    }
    if (length($probe_config) || $spider_port || $web_port || $admin_port) {
        my $probes = read_probes();
        for my $r (@start) {
            next unless exists $probes->{$r};
            my $v = $u->{$r};
            my $ok = eval{
                if ($v->{confirmed}) {
                    probe_unit($r, $probes->{$r}, $v)
                } elsif ($r eq 'spider' && @manual == 1 && $v->{ok} && unit_stopped($v)) {
                    manual_contract($manual[0], $probes->{$r})
                } else {
                    fail('no confirmed running service')
                }1
            };
            print $ok?"PROBE $r PASS (listener owner and response verified)\n":"PROBE $r BLOCK: $@";
        }
    }
    if ($check_remote) {
        print "CHECK REMOTE primary $remote[0] branch=$branch\n";
        my $a = remote_head($remote[0], $branch);
        print "CHECK REMOTE mirror $remote[1] branch=$branch\n";
        my $b = remote_head($remote[1], $branch);
        print "REMOTE primary ", ($a//'UNAVAILABLE'), "\nREMOTE mirror ", ($b//'UNAVAILABLE'), "\n";
        print 'REMOTE RESULT ', defined($a)
            && defined($b)?($a eq $b?'MATCH':'MISMATCH'):defined($a)?'PRIMARY_ONLY':defined($b)?'MIRROR_ONLY_UNCONFIRMED_FRESHNESS':'UNAVAILABLE', "\n";
        print 'REVISION RESULT ', revision_status($root, $a, $b), "\n";
    }
    print "RESULT BLOCK; production activation disabled; verify preflight results\n";
    return 2;
}

sub read_probes {
    if ($systemd_fixture) {
        my $p = $systemd_fixture->{ports};
        return {spider => {type => 'prompt', port => $p->{spider}, expect => 'login: '},
            web => {type => 'title', port => $p->{web}, path => '/', status => 200,
                expect => 'DXSpider Web'}, admin => {type => 'title', port => $p->{admin}, path => '/',
                status => 200, expect => 'DXSpider Web Supervision'}};
    }
    return {($spider_port?(spider => {type => 'prompt', port => $spider_port,
            expect => 'login: '}):()),
        ($web_port?(web => {type => 'title', port => $web_port, path => '/', status => 200,
            expect => 'DXSpider Web'}):()), ($admin_port?(admin => {type => 'title',
            port => $admin_port,
            path => '/', status => 200, expect => 'DXSpider Web Supervision'}):())}
        unless length $probe_config;
    path_check($probe_config);
    fail('probe configuration must be canonical, outside installation')
        unless (realpath($probe_config)//'') eq $probe_config && !under($probe_config, $root);
    my $dir = dirname($probe_config);
    while (1) {
        my @d = lstat($dir);
        fail('untrusted probe configuration ancestor') unless @d && S_ISDIR($d[2]) && $d[4] == 0
            && !($d[2]&0022);
        last if $dir eq '/';
        $dir = dirname($dir)
    }
    sysopen my $fh, $probe_config, O_RDONLY|O_NOFOLLOW or fail('cannot open probe configuration');
    my @s = stat($fh);
    fail('unsafe probe configuration') unless @s && S_ISREG($s[2]) && $s[4] == 0 && !($s[2]&0022)
        && $s[7] <= 32768;
    my $raw = '';
    my $n = read($fh, $raw, 32769);
    close $fh;
    fail('invalid probe configuration size') unless defined($n) && $n == $s[7] && $n <= 32768;
    my $p = $json->decode($raw);
    fail('probe config must be an object') unless ref($p) eq 'HASH';
    for my $r (keys %$p) {
        my $v = $p->{$r};
        fail('invalid probe role') unless exists $units{$r} && ref($v) eq 'HASH';
        my %allowed = map {$_ => 1} qw(type port expect path status);
        fail('unknown probe field') if grep {!$allowed{$_}} keys %$v;
        fail('invalid probe') unless ($v->{type}//'') =~  /\A(?:banner|prompt|http|title)\z/
            && ($v->{port}//'') =~  /\A\d+\z/ && $v->{port}>0 && $v->{port}<65536
            && defined($v->{expect}) && !ref($v->{expect}) && length($v->{expect})
            && length($v->{expect}) <= 4096;
        if ($v->{type} eq 'http' || $v->{type} eq 'title') {
            fail('invalid HTTP probe') unless ($v->{path}//'') =~ m{\A/[^\x00-\x20\x7f]*\z} && ($v->{status}//'') =~ /\A[1-5]\d\d\z/
        }
    }
    return $p;
}

sub probe_service {
    my ($r, $p) = @_;
    fail("missing confirmed functional probe for $r") unless ref($p) eq 'HASH';
    my $ok = eval {
        local $SIG{ALRM} = sub{
            die "probe timeout\n"
        };
        alarm 5;
        my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $p->{port},
            Proto => 'tcp', Timeout => 3) or die "connect failed\n";
        if ($p->{type} eq 'http' || $p->{type} eq 'title') {
            print {$sock} "GET $p->{path} HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n" or die "probe write failed\n"
        }
        my $reply = '';
        my $matched = 0;
        while (length($reply)<65536) {
            my $n = sysread($sock, my $b, 4096);
            die "probe read failed\n" unless defined $n;
            last unless $n;
            $reply .= $b;
            if ($p->{type} eq 'prompt') {
                $matched = index($reply, $p->{expect}) == 0;
                last if $matched
            }
            elsif ($p->{type} eq 'banner') {
                $matched = index($reply, $p->{expect}) >= 0;
                last if $matched
            }
            elsif($reply =~ m{\AHTTP/1\.[01] (\d{3})[^\r\n]*\r\n} && $1==$p->{status}) {
                my $i = index($reply, "\r\n\r\n");
                $matched = $i >= 0 && index(substr($reply, $i+4), $p->{expect}) >= 0;
                if ($p->{type} eq 'title') {
                    my($title)=$i>=0?substr($reply,$i+4)=~m{<title\b[^>]*>([^<\r\n]{1,200})</title>}i:();
                    $matched = defined($title) && index($title, $p->{expect}) == 0;
                    $matched = 0 if $r eq 'web' && $p->{expect} eq 'DXSpider Web' && defined($title)
                    && index($title, 'DXSpider Web Supervision') == 0;
                }
                last if $matched
            }
        }
        close $sock;
        alarm 0;
        die "functional response mismatch\n" unless $matched;
        1;
    };
    alarm 0;
    fail("functional probe failed for $r") unless $ok;
}

sub probe_unit {
    my ($r, $p, $v) = @_;
    fail("missing confirmed functional probe for $r") unless ref($p) eq 'HASH';
    fail("unconfirmed unit for $r") unless unit_definition_ok($v) && $v->{confirmed};
    my $id = unit_identity($v);
    my $socket = require_listener($r, $p->{port}, unit_members($v));
    probe_service($r, $p);
    my $after = unit_info($r, $v->{name});
    fail("unit changed during probe $r") unless unit_definition_ok($after) && $after->{confirmed}
        && same($after->{unit_sha}, $v->{unit_sha}) && unit_identity($after) eq $id;
    fail("listener changed during probe $r") unless require_listener($r, $p->{port},
        unit_members($after)) eq $socket;
}

sub required_runtime_modules {
    return qw(
        EV Mojolicious JSON JSON::XS Data::Structure::Util Math::Round Net::CIDR::Lite DBI
        DBD::SQLite Date::Parse HTML::Parser IO::Socket::INET6 Archive::Zip Curses
        Mail::Internet Digest::SHA LWP::UserAgent LWP::Parallel::UserAgent DB_File IO::Pty
        Authen::SASL Net::SMTP::SSL Email::Sender
    );
}

sub missing_runtime_modules {
    my ($includes, @prefix) = @_;
    my @missing;
    for my $m (required_runtime_modules()) {
        my ($ok) = capture_status('timeout', '15', @prefix, $^X, @$includes, '-e',
            'my $m=shift; (my $f=$m)=~s!::!/!g; exit(eval { require "$f.pm"; $m->VERSION(7.26) if $m eq "Mojolicious"; 1 } ? 0 : 1);', $m);
        push @missing, $m unless $ok
    }
    return @missing;
}

sub runtime_modules {
    my @missing = missing_runtime_modules(["-I$root/local", "-I$root/perl"], as_owner());
    print 'RUNTIME dependency inventory (Bash v0.6.22): ', (@missing?'MISSING '.join(',',
        @missing):'OK'), "\n";
    return !@missing;
}

# Fixture process adapter. Workers are actual independent writers. Signals are
# sent only to exact argv + nonce + workspace matches, checked again immediately.

# ==========================================================================
# 07. Isolated fixture workers
# ==========================================================================

sub fixture_marker {
    my ($b) = @_;
    path_check($b);
    fail('fixture location forbidden') if under($b, '/spider') || under($b, '/tmp')
        || under($b, '/var/tmp');
    fail('unsafe fixture root') unless (realpath($b)//'') eq $b && -f "$b/.fixture"
        && !-l "$b/.fixture";
    my @s = stat($b);
    fail('fixture ownership/mode invalid') unless $s[4] == $> && !($s[2]&0077);
    my $t = read_file("$b/.fixture");
    fail('invalid fixture marker') unless $t =~  /\A[0-9a-f]{48}\z/;
    return $t;
}

sub fixture_pids {
    my ($r) = @_;
    my @p;
    my $t = fixture_marker($base);
    for my $pid (all_pids()) {
        my $p = proc_info($pid) or next;
        my @a = @{$p->{argv}};
        next unless @a == 10 && (realpath($a[0])//'') eq (realpath($^X)//'') && $a[1] eq $script
            && join("\0", @a[2..9]) eq join("\0", '--mode', 'worker', '--base', $base, '--role', $r,
            '--token', $t);
        push @p, $p
    }
    return @p;
}

sub fixture_db_connect {
    require DBI;
    require DBD::SQLite;
    my $h = DBI->connect('dbi:SQLite:dbname=local_data/fixture.db', '', '', {RaiseError => 1,
        PrintError => 0});
    $h->do('PRAGMA journal_mode=WAL');
    $h->do('CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY, stamp INTEGER NOT NULL)');
    return $h;
}

sub worker {
    my $t = fixture_marker($base);
    fail('invalid worker identity') unless $token eq $t && exists $units{$role};
    my $r = "$base/live";
    fail('fixture live absent') unless -d "$r/local_data" && !-l "$r/local_data";
    chdir($r) or fail('worker cwd');
    my $db;
    my $db_enabled = $role eq 'spider' && -f "$base/sqlite.enabled";
    my $ticks = 0;
    my $stopper = sub{
        eval{
            $db->disconnect if $db
        };
        exit 0
    };
    $SIG{TERM} = $stopper;
    $SIG{INT} = $stopper;
    while (1) {
        open my $h, '>>', "local_data/$role.writer" or exit 4;
        print {$h} time." $$\n" or exit 5;
        close $h or exit 6;
        if ($role eq 'spider') {
            my $p = 'local_data/transient.writer';
            open my $w, '>', $p or exit 7;
            print {$w} "transient\n";
            close $w;
            unlink $p;
            # When DXSpider's own SQLite modules are present, generate real WAL traffic
            # and periodically close/reopen the connection, reproducing WAL/SHM churn.
            if ($db_enabled) {
                $db ||= fixture_db_connect();
                $db->do('INSERT INTO events(stamp) VALUES (?)', undef, time);
                if (++$ticks%8 == 0) {
                    $db->disconnect;
                    undef $db
                }
            }
        }
        sleep .08;
    }
}

sub worker_start {
    my ($r) = @_;
    return if fixture_pids($r);
    my $pid = fork();
    fail('fork failed') unless defined $pid;
    if (!$pid) {
        setsid();
        open STDIN, '<', '/dev/null';
        open STDOUT, '>>', "$base/workers.log";
        open STDERR, '>&', \*STDOUT;
        exec {$^X} $^X, $script, '--mode', 'worker', '--base', $base, '--role', $r, '--token',
            fixture_marker($base) or POSIX::_exit(127)
    }
    for (1..100) {
        return if fixture_pids($r);
        sleep .03
    }
    fail("worker $r start timeout")
}

sub worker_stop {
    my ($r) = @_;
    for my $p (fixture_pids($r)) {
        my $again = proc_info($p->{pid});
        fail('worker PID identity changed') unless $again && $again->{start} eq $p->{start}
            && join("\0", @{$again->{argv}}) eq join("\0", @{$p->{argv}});
        kill('TERM', $p->{pid}) or fail("worker stop $r: $!")
    }
    for (1..100) {
        waitpid(-1, WNOHANG);
        return unless fixture_pids($r);
        sleep .03
    }
    fail("worker $r stop timeout")
}

# Manual lifecycle: the journal owns identities, not arbitrary PID numbers.
# pidfd makes the signal target stable even if the numeric PID is reused.

# ==========================================================================
# 08. Manual process lifecycle and PID safety
# ==========================================================================

sub boot_id {
    my $b = read_file('/proc/sys/kernel/random/boot_id');
    chomp $b;
    fail('invalid boot identity') unless $b =~ /\A[0-9a-f-]{36}\z/;
    return $b
}

sub pidfd_numbers {
    my $ok = eval {
        require 'syscall.ph';
        1
    };
    fail('manual lifecycle requires Linux pidfd syscall definitions') unless $ok
        && defined(&SYS_pidfd_open) && defined(&SYS_pidfd_send_signal);
    return (SYS_pidfd_open(), SYS_pidfd_send_signal());
}

sub pidfd_open {
    my ($pid) = @_;
    my ($op) = pidfd_numbers();
    my $fd = syscall($op, 0+$pid, 0);
    fail("pidfd_open failed: $!") if $fd<0;
    open my $h, '<&=', $fd or fail("pidfd handle: $!");
    fcntl($h, F_SETFD, FD_CLOEXEC) or fail('pidfd close-on-exec');
    return $h;
}

sub manual_guard {
    return if LIVE_ENABLED && !$fixture && $> == 0;
    if ($fixture && defined($base) && $root eq "$base/live" && defined($work)
        && $work eq "$base/.dxs-updater-live") {
        fixture_marker($base);
        return
    }
    fail('live disabled: manual lifecycle');
}

sub proc_groups {
    my ($pid) = @_;
    my ($s) = optional_read("/proc/$pid/status") =~ /^Groups:[ \t]*([^\n]*)/m;
    fail('cannot inspect supplementary groups') unless defined $s;
    return [sort {$a<=>$b} grep {length} split /\s+/, $s]
}

sub manual_contract {
    my ($p, $probe) = @_;
    fail('manual launch not confirmed') unless manual_launch_match($p) && @{$p->{argv}} == 2;
    my $exe = readlink("/proc/$p->{pid}/exe")//'';
    fail('unsafe Perl executable') unless $exe eq realpath($^X) && -f $exe && -x $exe;
    my @e = stat($exe);
    fail('untrusted Perl executable') unless $e[4] == 0 && !($e[2]&0022);
    my $groups = proc_groups($p->{pid});
    my $home = (getpwuid($p->{uid}))[7];
    my $user = getpwuid($p->{uid});
    fail('manual account missing') unless defined($home) && defined($user);
    my $id = {pid => $p->{pid}, start => $p->{start}, boot => boot_id()};
    my $h = pidfd_open($p->{pid});
    my $again = proc_info($p->{pid});
    fail('manual identity changed during preflight') unless $again
        && manual_probe_identity($again) eq manual_probe_identity($p);
    close $h;
    my $s = {exists => 1, initial => 1, desired => 1, kind => 'manual', uid => $p->{uid},
        gid => $p->{gid}, groups => $groups, home => $home, user => $user, exe => $exe,
        initial_process => {%$id}, initial_argv => [@{$p->{argv}}], initial_cwd => $p->{cwd},
        process => $id, probe => $probe};
    manual_probe($s) if $probe;
    return $s;
}

sub manual_process {
    my ($s) = @_;
    my $id = $s->{process};
    return undef unless $id && $id->{boot} eq boot_id();
    my $p = proc_info($id->{pid});
    return undef unless $p && $p->{start} eq $id->{start};
    if ($s->{launch_pending} && @{$p->{argv}} != 2) {
        for (1..30) {
            sleep .1;
            $p = proc_info($id->{pid});
            return undef unless $p && $p->{start} eq $id->{start};
            last if @{$p->{argv}} == 2
        }
    }
    fail('journal manual PID no longer matches launch contract') unless $p->{uid} == $s->{uid}
        && $p->{gid} == $s->{gid} && $p->{ruid} == $s->{uid} && $p->{rgid} == $s->{gid}
        && $json->encode(proc_groups($p->{pid})) eq $json->encode($s->{groups})
        && (readlink("/proc/$p->{pid}/exe")//'') eq $s->{exe} && @{$p->{argv}} == 2
        && basename($p->{argv}[0]) =~ /\Aperl(?:[0-9.]+)?\z/ && ($p->{argv}[1] eq './cluster.pl'
        || $p->{argv}[1] eq 'cluster.pl' || $p->{argv}[1] eq "$root/perl/cluster.pl")
        && ($p->{cwd} eq $root || $p->{cwd} eq "$root/perl");
    return $p;
}

sub manual_probe {
    my ($s) = @_;
    my $p = manual_process($s) or fail('manual process not running');
    my $probe = $s->{probe} or fail('manual probe required');
    my $known = {$p->{pid} => $p->{start}};
    my $socket = require_listener('spider', $probe->{port}, $known);
    probe_service('spider', $probe);
    my $after = manual_process($s);
    fail('manual process changed during probe') unless $after
        && manual_probe_identity($after) eq manual_probe_identity($p) && require_listener('spider',
        $probe->{port}, $known) eq $socket;
}

sub manual_unit_safe {
    my ($s) = @_;
    return if $fixture;
    my $v = unit_info('spider', $s->{unit_name});
    fail('DXSpider systemd state changed during manual transaction') unless $v->{ok}
        && ($v->{LoadState}//'') eq $s->{unit_load} && unit_stopped($v)
        && ($s->{unit_load} eq 'not-found' || (unit_definition_ok($v)
        && same($v->{unit_sha}, $s->{unit_sha})));
}

sub manual_stop {
    my ($s) = @_;
    manual_guard();
    manual_unit_safe($s);
    my $p = manual_process($s);
    return unless $p;
    my $h = pidfd_open($p->{pid});
    my $sel = IO::Select->new($h);
    # A process can exit between opening the pidfd and revalidating /proc.
    if ($sel->can_read(0)) {
        waitpid($p->{pid}, WNOHANG);
        close $h;
        return
    }
    my $a = eval{
        manual_process($s)
    };
    my $err = $@;
    unless ($a && manual_probe_identity($p) eq manual_probe_identity($a)) {
        if ($sel->can_read(.25)) {
            waitpid($p->{pid}, WNOHANG);
            close $h;
            return
        }
        close $h;
        fail('manual identity changed before signal'.($err?' (contract rejected)':''));
    }
    my (undef, $sig) = pidfd_numbers();
    my $rc = syscall($sig, fileno($h), 15, 0, 0);
    if ($rc<0) {
        my $err = "$!";
        if ($sel->can_read(.25)) {
            waitpid($p->{pid}, WNOHANG);
            close $h;
            return
        }
        close $h;
        fail("manual TERM failed: $err")
    }

    # The kernel handle identifies the exact process already authorized for TERM.
    # During exit cwd, exe, argv and credentials may disappear or change BEFORE
    # the task reaches zombie state. Do not revalidate its launch contract then,
    # or mistake a failed /proc observation for successful termination.
    # A readable pidfd proves exit, also for non-child processes. No SIGKILL.

    my $deadline = Time::HiRes::time()+30;
    while (Time::HiRes::time()<$deadline){if($sel->can_read(.1)) {
            waitpid($p->{pid}, WNOHANG);
            close $h;
            return
        }
    }
    close $h;
    fail('manual DXSpider did not stop after TERM');
}

sub manual_start {
    my ($s) = @_;
    manual_guard();
    manual_unit_safe($s);
    return if manual_process($s);
    fail('manual start requires actual active tree') unless -f "$root/perl/cluster.pl"
        && !-l "$root/perl" && !-l "$root/perl/cluster.pl"
        && (realpath("$root/perl")//'') eq "$root/perl";
    if (!$fixture) {
        my %u = map {$_ => unit_info($_)} qw(web admin);
        require_no_unknown_writers(known_unit_processes(\%u), $root)
    } else {
        my %k;
        for my $r (qw(web admin)) {
            $k{$_->{pid}} = $_->{start} for fixture_pids($r)
        }require_no_unknown_writers(\%k, $root)
    }

    # Parent records PID/start/boot before releasing a child to execute. If the
    # updater dies before the release, EOF makes the child exit without exec.

    my $log = "$work/manual-spider.log";
    sysopen my $out, $log, O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW, 0600 or fail("manual log: $!");
    my @ls = stat($out);
    fail('unsafe manual log') unless @ls && S_ISREG($ls[2]) && $ls[3] == 1 && $ls[4] == $>
        && !($ls[2]&0077);
    $out->sync or fail('sync manual log');
    sync_dir($work);
    pipe(my $rd, my $wr) or fail('manual launch pipe');
    my $pid = fork();
    fail('manual fork failed') unless defined $pid;
    if (!$pid) {
        close $lock if defined $lock;
        close $wr;
        my $n = sysread($rd, my $go, 1);
        POSIX::_exit(125) unless defined($n) && $n == 1 && $go eq 'G';
        close $rd;
        eval {
            defined(setsid()) && getpgrp() == $$ or die 'setsid';
            open STDIN, '<', '/dev/null' or die 'stdin';
            open STDOUT, '>&', $out or die 'stdout';
            open STDERR, '>&', \*STDOUT or die 'stderr';
            close $out;
            if ($> == 0) {
                $) = join(' ', $s->{gid}, @{$s->{groups}});
                $( = $s->{gid};
                POSIX::setgid($s->{gid}) == 0 or die 'setgid';
                POSIX::setuid($s->{uid}) == 0 or die 'setuid';
            }
            die 'credentials' unless $> == $s->{uid} && $< == $s->{uid} && 0+$) == $s->{gid}
                && 0+$( == $s->{gid};
            die 'supplementary groups' unless $json->encode(proc_groups($$)) eq $json->encode($s->{groups});
            chdir("$root/perl") or die 'chdir';
            %ENV = (PATH => '/usr/sbin:/usr/bin:/sbin:/bin', HOME => $s->{home}, USER => $s->{user},
                LOGNAME => $s->{user}, LC_ALL => 'C');
            # All other descriptors, including the updater lock, close on exec.
            exec {$s->{exe}} $s->{exe}, './cluster.pl' or die 'exec';
        };
        print STDERR "manual launcher failed: $@\n";
        POSIX::_exit(127);
    }
    close $rd;
    close $out;
    my $p = proc_info($pid) or fail('manual child identity unavailable');
    $s->{process} = {pid => $pid, start => $p->{start}, boot => boot_id()};
    $s->{launch_pending} = 1;
    checkpoint($j->{state});
    inject('crash-manual-before-release');
    {local $SIG{PIPE} = 'IGNORE';
        syswrite($wr, 'G') == 1 or fail('manual release failed')}close $wr;
    for (1..300) {
        my $q = proc_info($pid);
        fail('manual child exited before exec') unless $q && $q->{start} eq $s->{process}{start};
        my $a = eval{
            manual_process($s)
        };
        if ($a) {
            delete $s->{launch_pending};
            checkpoint($j->{state});
            inject('crash-manual-after-release');
            my $deadline = time+60;
            while (time<$deadline) {
                fail('manual process exited before readiness') unless manual_process($s);
                return if eval{
                    manual_probe($s);
                    1
                };
                sleep .25
            }
            fail('manual service readiness timeout')
        }
        sleep .1
    }
    fail('manual exec identity timeout');
}


# ==========================================================================
# 09. Service adapters and service policy
# ==========================================================================

sub checked_unit {
    my ($r) = @_;
    my $v = unit_info($r, transaction_unit_name($r));
    fail("unit $r changed or unconfirmed") unless unit_definition_ok($v) && same($v->{unit_sha},
        $j->{services}{$r}{unit_sha});
    return $v;
}

sub adapter_state {
    my ($r) = @_;
    if (($j && ($j->{services}{$r}{kind}//'') eq 'manual')) {
        manual_unit_safe($j->{services}{$r});
        return manual_process($j->{services}{$r})?1:0
    }
    return scalar(fixture_pids($r))?1:0 if $fixture && !$systemd_fixture;
    my $v = checked_unit($r);
    return 0 if unit_stopped($v);
    fail("unknown unit state $r") unless $v->{confirmed} && $v->{ActiveState} eq 'active';
    return 1;
}

sub adapter_stop {
    my ($r) = @_;
    if (($j && ($j->{services}{$r}{kind}//'') eq 'manual')) {
        manual_stop($j->{services}{$r});
        return
    }
    if ($fixture && !$systemd_fixture) {
        worker_stop($r);
        return
    }
    fail('live disabled') unless LIVE_ENABLED || $systemd_fixture;
    systemd_fixture_guard($r) if $systemd_fixture;
    my $v = checked_unit($r);
    if ($j->{state} eq 'STOPPING') {
        if ($j->{services}{$r}{initial}) {
            fail("unit changed since preflight: $r") unless $v->{confirmed}
                && ($v->{ActiveState}//'') eq 'active'
                && unit_identity($v) eq ($j->{services}{$r}{initial_identity}//'')
        }
        else {
            fail("inactive unit changed since preflight: $r")
                unless ($v->{ActiveState}//'') eq 'inactive' && unit_stopped($v)
        }
    }
    return if unit_stopped($v);
    fail("unsafe active identity $r") if $v->{ActiveState} eq 'active' && !$v->{confirmed};
    fail("unsafe transition $r") unless $v->{ActiveState} eq 'active' && $v->{confirmed};
    run('timeout', '90', 'systemctl', 'stop', transaction_unit_name($r));
    fail("unit still running or not quiescent $r") unless unit_stopped(checked_unit($r));
}

sub adapter_start {
    my ($r) = @_;
    if (($j && ($j->{services}{$r}{kind}//'') eq 'manual')) {
        manual_start($j->{services}{$r});
        return
    }
    if ($fixture && !$systemd_fixture) {
        worker_start($r);
        return
    }
    fail('live disabled') unless LIVE_ENABLED || $systemd_fixture;
    systemd_fixture_guard($r) if $systemd_fixture;
    return if adapter_state($r);
    run('timeout', '90', 'systemctl', 'start', transaction_unit_name($r));
    for (1..40) {
        my $v = checked_unit($r);
        return if $v->{confirmed} && $v->{ActiveState} eq 'active';
        last if ($v->{ActiveState}//'') eq 'failed';
        sleep .25
    }
    fail("unit not running $r");
}

sub quiescent {
    for my $r (@stop) {
        next unless $j->{services}{$r}{exists};
        fail("writer $r still active") if adapter_state($r)
    }
    my $tw = tree_work();
    require_no_unknown_writers({}, $root, "$tw/old", "$tw/candidate", "$tw/failed");
}

sub service_plan {
    my %s;
    if ($fixture && !$systemd_fixture) {
        my $cfg = $json->decode(read_file("$base/services.json"));
        my %known;
        for my $r (@stop) {
            my $exists = $cfg->{$r}?1:0;
            my @p = fixture_pids($r);
            fail("unexpected worker $r") if @p>1 || (!$exists && @p);
            $known{$_->{pid}} = $_->{start} for @p;
            my $active = @p?1:0;
            $s{$r} = {exists => $exists, initial => $active,
                desired => $exists?($r eq 'spider'?$active:1):0}
        }
        if (-f "$base/manual-seed.json") {
            fail('manual fixture requires explicit launch directory')
                unless $manual_launch_dir eq "$root/perl";
            my $seed = $json->decode(read_file("$base/manual-seed.json"));
            my $p = manual_process($seed) or fail('initial fixture manual process missing');
            $s{spider} = manual_contract($p, $seed->{probe});
            $known{$p->{pid}} = $p->{start};
        }
        require_no_unknown_writers(\%known, $root);
    } else {
        my ($u, $blocks) = service_inventory();
        fail(join('; ', @$blocks)) if @$blocks;
        if ($approved_services) {
            for my $r (@start) {
                my $a = $approved_services->{roles}{$r};
                my $v = $u->{$r};
                fail("service selection changed: $r") unless ($a->{unit}//'') eq ($v->{name}//'');
                if ($a->{unit_info}) {
                    fail("service definition or identity changed: $r")
                        unless same($a->{unit_info}{unit_sha}, $v->{unit_sha})
                        && unit_identity($a->{unit_info}) eq unit_identity($v);
                } elsif ($a->{manual}) {
                    my $g = $a->{manual_unit_guard};
                    fail('manual companion unit changed') unless $g
                        && ($v->{LoadState}//'') eq ($g->{load}//'')
                        && ($v->{unit_sha}//'') eq ($g->{sha}//'')
                        && unit_identity($v) eq $g->{identity};
                } else {
                    fail("service appeared: $r") unless ($v->{LoadState}//'') eq 'not-found';
                }
            }
        }
        my $probes = read_probes();
        my $known = known_unit_processes($u);
        my @manual;
        for my $q (unknown_writers($known, $root)) {
            my $p = proc_info($q->[0]) or fail('process inventory changed; repeat preflight');
            if (manual_launch_match($p)) {
                push @manual, $p
            } else {
                fail('unmanaged process references installation; leave directory or stop independently: '.$p->{pid})
            }
        }
        fail('multiple manual DXSpider candidates') if @manual>1;
        if ($approved_services) {
            my $a = $approved_services->{roles}{spider};
            fail('manual service changed after approval')
                unless ($a->{manual}?1:0) == scalar(@manual)
                && (!@manual || manual_probe_identity($a->{process}) eq manual_probe_identity($manual[0]));
        }
        for my $r (@stop) {
            my $v = $u->{$r};
            my $exists = ($v->{LoadState}//'') eq 'loaded';
            my $active = $exists && ($v->{ActiveState}//'') eq 'active';
            my $desired = $exists && ($r ne 'spider' || $active);
            fail("unsafe unit state $r") unless $v->{ok} && ((!$exists
                && ($v->{LoadState}//'') eq 'not-found' && unit_stopped($v)) || ($exists
                && unit_definition_ok($v) && (($active && $v->{confirmed})
                || (($v->{ActiveState}//'') eq 'inactive' && unit_stopped($v)))));
            if ($r eq 'spider' && @manual) {
                fail('manual and systemd DXSpider conflict') if $active;
                fail('manual functional probe required') unless $probes->{$r};
                $s{$r} = manual_contract($manual[0], $probes->{$r});
                $s{$r}{unit_load} = $v->{LoadState};
                $s{$r}{unit_name} = $v->{name};
                $s{$r}{unit_sha} = $v->{unit_sha};
                next
            }

            fail("confirmed functional probe required for $r") if ($active || $desired)
                && !$probes->{$r};
            probe_unit($r, $probes->{$r}, $v) if $active;
            $s{$r} = {exists => $exists?1:0, initial => $active?1:0, desired => $desired?1:0,
                unit_name => $v->{name}, unit_sha => $v->{unit_sha}, initial_pid => $v->{MainPID},
                initial_start => $v->{pid_start}, initial_identity => unit_identity($v),
                probe => $probes->{$r}};
        }
    }
    return \%s;
}

# ==========================================================================
# 10. Transaction preparation, activation and rollback
# ==========================================================================

sub prepare {
    fail('existing journal; inspect/recover/archive; do not overwrite')
        if exists_path("$work/journal.json");
    my @urls = source_urls();
    my $primary = remote_head($urls[0], $branch);
    if (revision_status($root, $primary, undef) eq 'UP_TO_DATE') {
        print "UP_TO_DATE $primary branch=$branch; no clone, copy or service actions; local files unchanged\n";
        return
    }no_mounts($root);
    tools_check();
    configure_tmp();
    for my $p (@persistent) {
        fail("missing/unsafe $p") unless -d "$root/$p" && !-l "$root/$p"
    }
    fail('missing or unsafe DXVars.pm') unless -f "$root/local/DXVars.pm"
        && !-l "$root/local/DXVars.pm";
    owner_tree_preflight($root);
    my $dirty = local_changes($root);
    if (length($dirty)) {
        print "LOCAL CHANGES outside persistence: ",
            $dirty eq 'NO_GIT'?'not a Git checkout':$json->encode([split /\0/, $dirty]), "\n";
        fail('explicit --accept-local-changes required; original retained') unless $allow_dirty
    }
    capacity(1);
    $j = {version => 1, root => $root, fixture => $fixture?1:0,
        systemd_fixture => $systemd_fixture?1:0,
        branch => $branch, old_id => ident($root), backup => $backup?1:0, reserve => $reserve,
        dirty_sha => local_fingerprint($root, $dirty), owner => $owner, group => $group};
    $j->{home_layout} = 1 if $home_fs;
    checkpoint('PLANNED');
    stage_git();
    capacity(0);
    checkpoint('STAGED');
    print "STAGED $j->{head} $j->{remote}\nWORKSPACE $work\n";
}

sub verify_started {
    my ($policy) = @_;
    if (!$fixture || $systemd_fixture) {
        my %seen;
        for (1..5) {
            for my $r (@start) {
                my $s = $j->{services}{$r};
                next unless $s->{exists};
                my $active = adapter_state($r);
                fail("unexpected service state $r") unless $active == $s->{$policy};
                next unless $active;
                my $identity = $s->{kind}
                    && $s->{kind} eq 'manual'?manual_probe_identity(manual_process($s)):unit_identity(checked_unit($r));
                fail("service restarted during verification $r") if defined($seen{$r})
                    && $seen{$r} ne $identity;
                $seen{$r} = $identity
            }
            sleep 1
        }
        for my $r (@start) {
            next unless $j->{services}{$r}{$policy};
            my $s = $j->{services}{$r};
            if (($s->{kind}//'') eq 'manual') {
                fail('manual process changed before probe')
                    unless manual_probe_identity(manual_process($s)) eq $seen{$r};
                manual_probe($s);
                next
            }
            my $v = checked_unit($r);
            fail("service restarted before probe $r") unless unit_identity($v) eq $seen{$r};
            probe_unit($r, $j->{services}{$r}{probe}, $v);
            fail("service failed after probe $r") unless adapter_state($r)
                && unit_identity(checked_unit($r)) eq $seen{$r}
        }
        return;
    }
    # Real-runtime evidence uses actual cluster.pl, not synthetic .writer files.
    if ($fixture && !$systemd_fixture && $base eq '/lab' && -f '/lab/real-runtime.json') {
        fail('real-runtime fixture isolation guard') unless $root eq '/lab/live'
            && (readlink('/spider')//'') eq '/lab/live' && -f '/lab/.fixture'
            && (optional_read('/proc/1/cmdline') =~  /real-isolated-check\.pl/);
        my $s = $j->{services}{spider};
        fail('real-runtime fixture contract') unless ($s->{kind}//'') eq 'manual'
            && !$j->{services}{web}{exists} && !$j->{services}{admin}{exists};
        if ($s->{$policy}) {
            my $p = manual_process($s) or fail('real DXSpider not running');
            my $id = manual_probe_identity($p);
            for (1..5) {
                manual_probe($s);
                sleep 1;
                my $q = manual_process($s);
                fail('real DXSpider changed identity') unless $q && manual_probe_identity($q) eq $id
            }
        }
        else {
            fail('unexpected real DXSpider process') if manual_process($s)
        }
        return;
    }
    my %sizes;
    for my $r (@start) {
        next unless $j->{services}{$r}{exists};
        my $active = adapter_state($r);
        fail("unexpected worker state $r") unless $active == $j->{services}{$r}{$policy};
        next unless $active;
        my $p = "$root/local_data/$r.writer";
        $sizes{$r} = (-s $p) || 0
    }
    sleep .35;
    for my $r (keys %sizes) {
        fail("writer $r not functional") unless adapter_state($r)
            && ((-s "$root/local_data/$r.writer")
            || 0)>$sizes{$r};
        manual_probe($j->{services}{$r}) if ($j->{services}{$r}{kind}//'') eq 'manual'
    }
}

sub restore_policy {
    my ($policy) = @_;
    for my $r (@start) {
        next unless $j->{services}{$r}{exists};
        if ($j->{services}{$r}{$policy}) {
            adapter_start($r)
        }  elsif (adapter_state($r)) {
            adapter_stop($r)
        }
    } verify_started($policy);
}

sub activate {
    fail('production activation disabled') unless $fixture || LIVE_ENABLED;
    my $tw = tree_work();
    owner_tree_preflight($root);
    fail('not staged') unless $j->{state} eq 'STAGED';
    fail('source replaced') unless same(ident($root), $j->{old_id});
    fail('candidate replaced') unless same(ident("$tw/candidate"), $j->{new_id});
    fail('local changes changed after plan') unless local_fingerprint($root,
        local_changes($root)) eq $j->{dirty_sha};
    if (($j->{operation}//'update') eq 'restore') {
        restore_candidate_check();
    } else {
        owner_file_call(sub {clean_git("$tw/candidate", $j->{head}, $j->{branch}, $j->{remote});
            return 1;
        });
        fail('staged Git version metadata changed')
        unless $json->encode(version_identity("$tw/candidate")) eq $json->encode($j->{git_version_metadata});
        fail('stale remote HEAD; prepare again') unless same(remote_head($j->{remote}, $j->{branch}),
        $j->{head});
        if ($j->{git_version_metadata}) {
            my @tags = version_tag_refs($j->{remote});
            fail('remote version tags changed; prepare again')
            unless same(sha256_hex($json->encode(\@tags)), $j->{git_version_remote_sha});
        }
        if ($j->{remote} ne $j->{primary_url}) {
            my $p = remote_head($j->{primary_url}, $j->{branch});
            fail('mirror differs from primary now reachable') if defined($p) && $p ne $j->{head}
        }
    }
    $backup = $j->{backup};
    $reserve = $j->{reserve};
    no_mounts($root);
    configure_tmp();
    capacity(0);
    fail('required DXSpider runtime modules missing') if !$fixture && !runtime_modules();
    $j->{services} = service_plan();
    ui_event('Stopping services in dependency order');
    checkpoint('STOPPING');
    for my $r (@stop) {
        next unless $j->{services}{$r}{exists};
        $j->{intent} = "stop:$r";
        checkpoint('STOPPING');
        inject("stop-$r");
        ui_event("Stopping $r");
        adapter_stop($r);
        ui_event("[ OK ] $r stopped");
        $j->{intent} = "stopped:$r";
        checkpoint('STOPPING')
    }quiescent();
    no_mounts($root);
    no_mounts("$tw/candidate");
    owner_tree_preflight($root);
    checkpoint('QUIESCENT');
    inject('crash-quiescent');
    capacity(0, 1);
    checkpoint('COPYING');
    my $candidate = "$tw/candidate";
    if (($j->{operation}//'update') eq 'restore') {
        restore_candidate_check();
        $j->{persist_sha} = manifest($candidate, @persistent);
        ui_event('Using the selected historical data; current tree will be retained');
    } else {
        ui_event("Copying and verifying the six persistent directories");
        $j->{persist_sha} = copy_persistent($root, $candidate);
    }
    quiescent();
    ui_event("Checking SQLite integrity");
    sqlite_check($candidate);
    fail('candidate persistence changed during validation') unless manifest($candidate,
        @persistent) eq $j->{persist_sha};
    if (($j->{operation}//'update') ne 'restore') {
        fail('original persistence changed after copy') unless manifest($root,
        @persistent) eq $j->{persist_sha};
        # Upstream data and nonpersistent source code must stay from the new HEAD.
        my $delta = local_changes($candidate);
        fail('new source code changed') if length $delta;
        fail('candidate Git revision changed') unless git_value($candidate, 'rev-parse',
        'HEAD') eq $j->{head} && git_value($candidate, 'symbolic-ref', '--short',
        'HEAD') eq $j->{branch} && git_value($candidate, 'config', '--get',
        'remote.origin.url') eq $j->{remote};
        run(git($candidate, 'fsck', '--full', '--no-dangling'));
        fail('candidate Git version metadata changed')
        unless $json->encode(version_identity($candidate)) eq $json->encode($j->{git_version_metadata});
        owner_file_call(sub {
            my @s = stat($root);
            chown($s[4], $s[5], $candidate) == 1 or fail('candidate root owner');
            chmod($s[2]&07777, $candidate) or fail('candidate root mode');
            return 1;
        });
    } else {
        restore_candidate_check();
    }
    if ($backup) {
        my $b = backup_sizes($root, 1);
        my ($mb, $mn) = capacity_margin($b->{bytes}, $b->{inodes});
        capacity_check($b->{bytes}+$mb, $b->{inodes}+$mn, 1);
        ui_event('Creating additional backup');
        checkpoint('BACKING_UP');
        $j->{backup_sha} = owner_file_call(sub {
            mkdir("$tw/backup", 0700) or fail('backup mkdir');
            return copy_backup($root, "$tw/backup/spider");
        });
        $j->{backup_excluded_contents} = [@backup_empty];
        sync_tree("$tw/backup");
    }
    $j->{old_sha} = manifest($root, '.');
    $j->{new_sha} = manifest($candidate, '.');
    sync_tree($candidate);
    sync_tree($root);
    checkpoint('PREPARED');
    inject('crash-prepared');
    quiescent();
    no_mounts($root);
    no_mounts($candidate);
    fail('original changed before activation') unless manifest($root, '.') eq $j->{old_sha};
    fail('source persistence no longer equals verified copy')
        if ($j->{operation}//'update') ne 'restore' && manifest($root,
        @persistent) ne $j->{persist_sha};
    ui_event('Activating candidate; retaining original');
    checkpoint('ACTIVATING');
    inject('rename-old');
    owner_file_call(sub {move_tree($root, "$tw/old"); return 1;});
    inject('old-renamed');
    inject('rename-new');
    owner_file_call(sub {move_tree($candidate, $root); return 1;});
    inject('new-renamed');
    fail('active identity mismatch') unless same(ident($root), $j->{new_id});
    fail('active manifest mismatch') unless manifest($root, '.') eq $j->{new_sha};
    fail('active persistence mismatch') unless manifest($root, @persistent) eq $j->{persist_sha};
    checkpoint('STARTING');
    for my $r (@start) {
        next unless $j->{services}{$r}{desired};
        $j->{intent} = "start:$r";
        checkpoint('STARTING');
        inject("start-$r");
        ui_event("Starting $r");
        adapter_start($r);
        ui_event("[ OK ] $r started")
    }
    inject('crash-started');
    inject('verify');
    ui_event('Verifying functional service endpoints and revision');
    verify_started('desired');
    fail('active Git revision changed during service startup') unless git_value($root, 'rev-parse',
        'HEAD') eq $j->{head} && git_value($root, 'symbolic-ref', '--short',
        'HEAD') eq $j->{branch};
    fail('active Git version metadata changed')
        unless $json->encode(version_identity($root)) eq $json->encode($j->{git_version_metadata});
    checkpoint('VERIFIED');
    sync_tree($root);
    checkpoint('COMMITTED');
    inject('committed');
    print "COMMITTED $j->{head}; original retained at $tw/old\n";
}

sub recover_tx {
    fail('production recovery disabled') unless $fixture || LIVE_ENABLED;
    my $state = $j->{state};
    my $tw = tree_work();
    if ($state eq 'COMMITTED') {
        fail('committed tree identity changed') unless same(ident($root), $j->{new_id});
        print "COMMITTED; no rollback\n";
        return
    }
    if ($state eq 'ROLLED_BACK') {
        fail('restored tree identity changed') unless same(ident($root), $j->{old_id});
        print "ROLLED_BACK; no action\n";
        return
    }
    if ($state eq 'PLANNED' || $state eq 'STAGED') {
        print "$state; no service actions or rename to recover\n";
        return
    }
    fail('unknown journal state')
        unless $state =~  /\A(?:STOPPING|QUIESCENT|COPYING|BACKING_UP|PREPARED|ACTIVATING|STARTING|VERIFIED|ROLLING_BACK|RECOVERY_REQUIRED)\z/;
    if (!-d $root) {
        fail('original tree identity unavailable') unless same(ident("$tw/old"), $j->{old_id});
        fail('missing real cluster.pl in original tree') unless -f "$tw/old/perl/cluster.pl"
            && !-l "$tw/old/perl" && !-l "$tw/old/perl/cluster.pl";
        my @st = stat("$tw/old/perl/cluster.pl");
        ($owner, $group) = @st[4, 5];
    }
    fail('missing initial service policy') unless ref($j->{services}) eq 'HASH';
    # Resolve actual directory identities first, including interruption between
    # rename and the following journal write. Never overwrite an unknown tree.
    my $live = ident($root);
    my $old = ident("$tw/old");
    my $cand = ident("$tw/candidate");
    my $failed = ident("$tw/failed");
    fail('unexpected old tree') if defined($old) && !same($old, $j->{old_id});
    fail('unexpected active tree') if defined($live) && !same($live, $j->{old_id})
        && !same($live, $j->{new_id});
    fail('unexpected candidate') if defined($cand) && !same($cand, $j->{new_id});
    fail('unexpected failed tree') if defined($failed) && !same($failed, $j->{new_id});
    fail('original missing or ambiguous') unless (same($live, $j->{old_id}) xor same($old,
        $j->{old_id}));
    checkpoint('ROLLING_BACK');
    if (defined($old)) {
        for my $r (@stop) {
            next unless $j->{services}{$r}{exists};
            adapter_stop($r)
        }quiescent();
        fail('old manifest mismatch') unless $j->{old_sha} && manifest("$tw/old",
            '.') eq $j->{old_sha};
        if (defined $live) {
            fail('failed destination occupied') if defined $failed;
            my $failed_persist = manifest($root, @persistent);
            $j->{reconciliation} = {status => ($failed_persist eq ($j->{persist_sha}//'')?'NO_PERSISTENCE_DRIFT':'REVIEW_REQUIRED'), baseline_sha => $j->{persist_sha}, failed_persist_sha => $failed_persist, failed_tree => "$tw/failed", policy => 'retain both; no automatic merge'};
            sync_tree($root);
            checkpoint('ROLLING_BACK');
            owner_file_call(sub {move_tree($root, "$tw/failed"); return 1;});
        } owner_file_call(sub {move_tree("$tw/old", $root); return 1;});
        fail('restored manifest mismatch') unless manifest($root, '.') eq $j->{old_sha};
    }
    fail('restored identity mismatch') unless same(ident($root), $j->{old_id});
    restore_policy('initial');
    checkpoint('ROLLED_BACK');
    print "ROLLED_BACK; candidate/failed data retained; no automatic merge\n";
    print "RECONCILIATION REVIEW_REQUIRED: failed tree contains persistence changes\n" if $j->{reconciliation} && $j->{reconciliation}{status} eq 'REVIEW_REQUIRED';
}

# ==========================================================================
# 11. Manual lifecycle test fixtures
# ==========================================================================

sub fixture_manual_program {
    return <<'PERL';
#!/usr/bin/perl
use strict;use warnings;use IO::Socket::INET;use IO::Select;use Time::HiRes qw(sleep);
chdir '..' or die 'fixture chdir';
open my $f,'<','local_data/manual.port' or die $!;my $port=<$f>;close $f;chomp $port;
my $s=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>$port,Proto=>'tcp',Listen=>8,ReuseAddr=>1) or die $!;
my $sel=IO::Select->new($s);$SIG{TERM}=sub{print STDERR "fixture graceful TERM: changing metadata before exit\n";chdir '..' or die $!;$0='fixture-stopping';sleep .20;exit 0};$SIG{PIPE}='IGNORE';
open my $r,'<','REVISION' or die $!;my $rev=<$r>;close $r;chomp $rev;
while(1){open my $h,'>>','local_data/spider.writer' or die $!;print {$h} "$rev $$\n";close $h or die $!;
 if($sel->can_read(.08)){my $c=$s->accept();if($c){print {$c} 'login: ';sleep .04;close $c}}
}
PERL
}

sub fixture_manual_seed {
    my $gid = 0+$);
    chown($>, $gid, "$base/live/perl/cluster.pl") == 1 or fail("manual fixture owner");
    $fixture = 1;
    $root = validate_root("$base/live", 0);
    $work = "$base/.dxs-updater-live";
    $manual_launch_dir = "$root/perl";
    my $port_sock = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1,
        Proto => 'tcp') or fail('fixture free port');
    my $port = $port_sock->sockport;
    close $port_sock;
    write_file("$root/local_data/manual.port", "$port\n");
    my $pid = fork();
    fail('fixture manual seed fork') unless defined $pid;
    if (!$pid) {
        setsid();
        chdir("$root/perl") or POSIX::_exit(1);
        open STDIN, '<', '/dev/null';
        open STDOUT, '>>', "$base/manual-seed.log";
        open STDERR, '>&', \*STDOUT;
        exec {$^X} $^X, './cluster.pl' or POSIX::_exit(127)
    }
    my $s;
    my $probe = {type => 'prompt', port => $port, expect => 'login: '};
    for (1..100) {
        my $p = proc_info($pid);
        if ($p && manual_launch_match($p)) {
            $s = eval{
                manual_contract($p, $probe)
            };
            last if $s
        }
        sleep .05
    }
    if (!$s) {
        kill 'TERM', $pid;
        waitpid($pid, 0);
        fail('fixture manual seed not ready')
    }
    write_file("$base/manual-seed.json", $json->encode($s));
    print "FIXTURE MANUAL SPIDER READY pid=$pid port=$port\n";
}

sub manual_selftest {
    path_check($base);
    fail('manual selftest forbidden path') if under($base, '/spider') || under($base, '/tmp')
        || under($base, '/var/tmp');
    fail('manual selftest existing base') if exists_path($base);
    fail('noncanonical parent') unless (realpath(dirname($base))//'') eq dirname($base);
    mkdir($base, 0700) or fail('manual test mkdir');
    my $top = $base;
    my $count = 0;
    my $check = sub{
        my ($ok, $s) = @_;
        fail("TEST $s") unless $ok;
        print "PASS $s\n";
        ++$count
    };
    my $cmd = sub{
        my ($b, $m, @a) = @_;
        system {$^X} $^X, $script, '--base', $b, '--mode', $m, '--branch', 'mojo', @a;
        return $? == -1?255:($?&127?128+($?&127):$?>>8)
    };
    for my $case (['manual-normal', '', 0, 'NEW'], ['manual-crash-before',
        'crash-manual-before-release', 73, 'OLD'], ['manual-crash-after',
        'crash-manual-after-release',
        73, 'OLD'], ['manual-verify-fail', 'verify', 1, 'OLD'], ['manual-stop-fail', 'stop-spider',
        1,
        'OLD']) {
        my ($name, $fault, $rc, $rev) = @$case;
        my $b = "$top/$name";
        my $live = "$b/live";
        my $w = "$b/.dxs-updater-live";
        my $ok = eval{
            $check->($cmd->($b, 'fixture-seed', '--fault', 'manual-spider') == 0, "$name seed");
            my $initial = $json->decode(read_file("$b/manual-seed.json"));
            $check->($cmd->($b, 'fixture-prepare') == 0, "$name prepare");
            if ($name eq 'manual-normal') {
                $check->($cmd->($b, 'fixture-update') != 0,
                    'manual launch without explicit directory blocked');
                $check->(proc_info($initial->{process}{pid})->{start} eq $initial->{process}{start},
                    'unapproved manual process not signaled');
            }
            my @args = ('--manual-launch-dir', "$live/perl");
            push @args, '--fault', $fault if length $fault;
            $check->($cmd->($b, 'fixture-update', @args) == $rc, "$name update exit $rc");
            if ($name =~ /\Amanual-crash-(before|after)\z/) {
                my $phase = $1;
                my $pre = $json->decode(read_file("$w/journal.json"));
                $check->($pre->{state} eq 'STARTING' && ($pre->{intent}//'') eq 'start:spider'
                    && same(ident($live), $pre->{new_id}) && same(ident("$w/old"), $pre->{old_id}),
                    "$name interruption occurred during candidate launch, not rollback");
                $check->(($pre->{services}{spider}{launch_pending}?1:0) == ($phase eq 'before'?1:0),
                    "$name launch release phase recorded");
            }
            $check->($cmd->($b, 'fixture-recover') == 0 && $cmd->($b, 'fixture-recover') == 0,
                "$name independent recovery twice");
            if ($name ne 'manual-stop-fail') {
                $check->(read_file("$b/manual-seed.log") =~ /fixture graceful TERM: changing metadata before exit/, "$name initial writer exited after changing process metadata");
            }
            my $j = $json->decode(read_file("$w/journal.json"));
            my $s = $j->{services}{spider};
            my $p = proc_info($s->{process}{pid});
            $check->(read_file("$live/REVISION") eq "$rev\n"
                && $j->{state} eq ($rev eq 'NEW'?'COMMITTED':'ROLLED_BACK'),
                "$name expected active revision and journal");
            $check->($p && $p->{start} eq $s->{process}{start} && $p->{cwd} eq $live
                && $p->{uid} == $initial->{uid} && $p->{gid} == $initial->{gid},
                "$name manual process identity and cwd");
            if ($name ne 'manual-stop-fail') {
                $check->($s->{process}{pid} != $initial->{process}{pid}
                    && $p->{session} == $p->{pid}
                    && $p->{tty_nr} == 0, "$name detached restart with new PID");
                $check->(readlink("/proc/$p->{pid}/fd/0") eq '/dev/null'
                    && readlink("/proc/$p->{pid}/fd/1") eq "$w/manual-spider.log",
                    "$name stdio protected outside live tree");
            }
            {local $base = $b; $fixture = 1; $root = $live; $work = $w; manual_probe($s);
                $check->(1, "$name verified actual login prompt with listener ownership");
                for my $r (qw(web admin)) {
                    $check->(scalar(fixture_pids($r)) == 1, "$name $r restored");
                }}
            $check->(-f "$live/local/record" && read_file("$live/local/record") eq "site-local\n",
                "$name persisted state");
            $check->(-d "$w/failed" && -f "$w/failed/local_data/spider.writer",
                "$name candidate data retained") if $name =~ /manual-(?:crash|verify)/;
            if ($name eq 'manual-normal') {
                $check->(-d "$w/old", 'manual original retained');
            }
            if ($name eq 'manual-verify-fail') {
                $check->($j->{reconciliation} && $j->{reconciliation}{status} eq 'REVIEW_REQUIRED',
                    'post-start persistence drift explicitly marked for review');
            }
            1;
        };
        my $err = $@;
        if (-f "$b/.fixture") {
            $cmd->($b, 'fixture-stop')
        }
        die $err unless $ok;
    }
    print "MANUAL TOTAL $count/$count PASS\nSAFETY fixture only; no real systemd actions or /spider mutation\n";
}


# ==========================================================================
# 12. Test fixtures and independent command entry points
# ==========================================================================

sub fixture_seed {
    path_check($base);
    fail('fixture location forbidden') if under($base, '/spider') || under($base, '/tmp')
        || under($base, '/var/tmp');
    fail('fixture base already exists') if exists_path($base);
    fail('noncanonical fixture parent') unless (realpath(dirname($base))//'') eq dirname($base);
    mkdir($base, 0700) or fail('fixture mkdir');
    write_file("$base/.fixture", random_token());
    my $repo = "$base/repo";
    mkdir($repo, 0700) or fail('repo mkdir');
    run('git', '-C', $repo, 'init', '-q');
    run('git', '-C', $repo, 'symbolic-ref', 'HEAD', "refs/heads/$branch");
    run('git', '-C', $repo, 'config', 'user.email', 'test@example.invalid');
    run('git', '-C', $repo, 'config', 'user.name', 'Updater fixture');
    for my $d ('perl', 'data', @persistent) {
        mkdir("$repo/$d", 0700) or fail("mkdir fixture $d")
    }
    write_file("$repo/perl/cluster.pl",
        $fault eq 'manual-spider'?fixture_manual_program():"#!/usr/bin/perl\nprint qq(old revision\\n);\n");
    write_file("$repo/data/upstream", "OLD DATA\n");
    write_file("$repo/REVISION", "OLD\n");
    for my $d (@persistent) {
        write_file("$repo/$d/record", "site-$d\n")
    }
    write_file("$repo/perl/systemd-fixture.pl", systemd_fixture_program())
        if $fault eq 'systemd-fixture';
    run('git', '-C', $repo, 'add', '.');
    run('git', '-C', $repo, 'commit', '-qm', 'old');
    run('git', 'clone', '-q', '--no-hardlinks', '--branch', $branch, $repo, "$base/live");
    for my $p ("$repo/REVISION", "$repo/data/upstream", "$repo/perl/cluster.pl") {
        unlink($p) or fail('fixture replace')
    }
    write_file("$repo/REVISION", "NEW\n");
    write_file("$repo/data/upstream", "NEW DATA\n");
    write_file("$repo/perl/cluster.pl",
        $fault eq 'manual-spider'?fixture_manual_program():"#!/usr/bin/perl\nprint qq(new revision\\n);\n");
    unlink "$repo/local/record" or fail('fixture record unlink');
    write_file("$repo/local/record", "UPSTREAM MUST NOT SURVIVE\n");
    write_file("$repo/filter/upstream-only", "must disappear\n");
    run('git', '-C', $repo, 'add', '.');
    run('git', '-C', $repo, 'commit', '-qm', 'new');
    my $r = "$base/live";
    write_file("$r/local/DXVars.pm", "1;\n");
    write_file("$r/local_data/name|with\nnewline", "content\x00\n");
    link("$r/local/record", "$r/filter/hardlink") or fail('hardlink fixture');
    symlink('../local/record', "$r/local_data/relative") or fail('relative link');
    symlink('/not/a/real/path', "$r/local_data/external") or fail('external link');
    run('touch', '-h', '-d', '@1700000000.123456789', "$r/local_data/external");
    chmod(0640, "$r/local/record") or fail('fixture permission');

    # Explicitly exercise extended metadata where tools are installed, without
    # making these tools dependencies of the updater itself.
    if (-x '/usr/bin/setfattr') {
        run('/usr/bin/setfattr', '-n', 'user.dxs_fixture', '-v', 'metadata', "$r/local/record");
        print "FIXTURE xattrs enabled\n"
    }
    if (-x '/usr/bin/setfacl') {
        run('/usr/bin/setfacl', '-m', 'u:12345:r--', "$r/local/record");
        print "FIXTURE ACL enabled\n"
    }
    if (eval{
        require DBI;
        require DBD::SQLite;
        1
    }) {
        my $cwd = realpath('.');
        chdir($r) or fail('fixture DB cwd');
        my $db = fixture_db_connect();
        $db->do('INSERT INTO events(stamp) VALUES (?)', undef, time);
        $db->disconnect;
        chdir($cwd) or fail('restore fixture cwd');
        write_file("$base/sqlite.enabled", "DBI\n");
        print "FIXTURE SQLite WAL writer enabled\n";
    }
    my $svc = {admin => 1, web => 1, spider => 1};
    $svc->{admin} = 0 if $fault eq 'absent-admin';
    write_file("$base/services.json", $json->encode($svc));
    if ($fault eq 'systemd-fixture') {
        print "FIXTURE READY $base (no workers)\n";
        return
    }
    if ($fault eq 'manual-spider') {
        fixture_manual_seed()
    } elsif ($fault ne 'inactive-spider') {
        worker_start('spider')
    }worker_start('web') unless $fault eq 'inactive-web';
    worker_start('admin') if $svc->{admin};
    print "FIXTURE READY $base\n";
}

sub fixture_context {
    fixture_marker($base);
    $fixture = 1;
    $root = validate_root("$base/live", $mode eq 'fixture-recover' || $mode eq 'fixture-inspect'
        || $mode eq 'systemd-fixture-cleanup');
    systemd_fixture_select();
}

sub setup_live {
    $fixture = 0;
    $root = validate_root($installation, $mode eq 'recover' || $mode eq 'inspect');
    fail('root required for host mutation') if $mode ne 'host-plan' && $> != 0;
    fail('pending clean installation requires recovery from Restore menu') if LIVE_ENABLED
        && $mode =~ /\A(?:prepare|update|recover|archive)\z/
        && install_pending_read(manager_state_directory(0));
}

sub inspect_tx {
    load_journal();
    print $json->pretty->encode($j);
    $json->pretty(0);
    my $tw = tree_work();
    for my $p ($root, map {"$tw/$_"} qw(old candidate failed backup)) {
        print "$p identity=", (ident($p)//'absent'), "\n"
    }
}

sub archive_tx {
    load_journal();
    my $state = $j->{state};
    fail('production reconciliation review required before another transaction') if !$fixture
        && $j->{reconciliation} && $j->{reconciliation}{status} eq 'REVIEW_REQUIRED';
    fail('unresolved transaction must not be archived')
        unless $state =~  /\A(?:PLANNED|STAGED|COMMITTED|ROLLED_BACK)\z/;
    my $expected = $state eq 'COMMITTED'?$j->{new_id}:$j->{old_id};
    fail('active tree identity changed') unless same(ident($root), $expected);
    my $dest = "$work-archive-".time.'-'.substr(random_token(), 0, 12);
    move_tree($work, $dest);
    print "ARCHIVED $state $dest; no data deleted\n";
    return $dest;
}

# Called only while holding the stable per-installation lock.
sub rollover_workspace {
    return unless exists_path("$work/journal.json");
    my $archived = archive_tx();
    ensure_workspace(1);
    $j = undef;
    return $archived;
}

sub execute_transaction {
    load_journal();
    my $ok = eval {
        local $SIG{INT} = sub {
            fail('interrupted')
        };
        local $SIG{TERM} = sub {
            fail('terminated')
        };
        activate();
        1
    };
    if (!$ok) {
        my $e = $@;
        print STDERR $e;
        if ($j->{state} !~ /\A(?:PLANNED|STAGED|COMMITTED)\z/) {
            my $r = eval {
                recover_tx();
                1
            };
            if (!$r) {
                my $err = $@;
                print STDERR "RECOVERY REQUIRED: $err";
                eval {
                    checkpoint('RECOVERY_REQUIRED')
                };
            }
        }
        return 1;
    }
    return 0;
}

sub do_update {
    my $status = execute_transaction();
    exit $status if $status;
}

sub do_recover {
    load_journal();
    my $ok = eval {
        recover_tx();
        1
    };
    if (!$ok) {
        my $e = $@;
        print STDERR "RECOVERY REQUIRED: $e";
        eval {
            checkpoint('RECOVERY_REQUIRED')
        }
        unless $j->{state} eq 'COMMITTED' || $j->{state} eq 'ROLLED_BACK';
        exit 1
    }
}

sub fixture_cleanup_workers {
    fixture_marker($base);
    worker_stop($_) for @stop;
    if (-f "$base/manual-seed.json") {
        $fixture = 1;
        $root = "$base/live";
        $work = "$base/.dxs-updater-live";
        my $s = $json->decode(read_file("$base/manual-seed.json"));
        if (-f "$work/journal.json") {
            $j = $json->decode(read_file("$work/journal.json"));
            $s = $j->{services}{spider} if $j->{services}
                && ($j->{services}{spider}{kind}//'') eq 'manual'
        }manual_stop($s)
    }
}

# ==========================================================================
# 13. Transaction regression tests
# ==========================================================================

sub selftest {
    path_check($base);
    fail('selftest location forbidden') if under($base, '/spider') || under($base, '/tmp')
        || under($base, '/var/tmp');
    fail('selftest base exists') if exists_path($base);
    fail('noncanonical parent') unless (realpath(dirname($base))//'') eq dirname($base);
    mkdir($base, 0700) or fail('selftest mkdir');
    my $top = $base;
    my $count = 0;
    my $check = sub {
        my ($ok, $s) = @_;
        fail("TEST $s") unless $ok;
        print "PASS $s\n";
        $count++
    };
    my $cmd = sub {
        my ($b, $m, @a) = @_;
        system {$^X} $^X, $script, '--base', $b, '--mode', $m, '--branch', 'mojo', '--reserve-gib',
            '0',
            @a;
        return $? == -1?255:($?&127?128+($?&127):$?>>8)
    };
    my @cases = (['normal', '', 0, 'NEW'], ['backup', '', 0, 'NEW'], ['inactive-web', '', 0, 'NEW'],
        ['inactive-spider', '', 0, 'NEW'], ['absent-admin', '', 0, 'NEW'], ['stop-fail', 'stop-web',
        1,
        'OLD'], ['copy-fail', 'copy', 1, 'OLD'], ['space-fail', 'space', 1, 'OLD'],
        ['rename-old-fail',
        'rename-old', 1, 'OLD'], ['rename-new-fail', 'rename-new', 1, 'OLD'], ['start-fail',
        'start-web', 1, 'OLD'], ['verify-fail', 'verify', 1, 'OLD'], ['crash-quiescent',
        'crash-quiescent', 73, 'OLD'], ['crash-prepared', 'crash-prepared', 73, 'OLD'],
        ['old-renamed',
        'old-renamed', 73, 'OLD'], ['new-renamed', 'new-renamed', 73, 'OLD'], ['sigkill',
        'sigkill-after-rename', 137, 'OLD'], ['crash-started', 'crash-started', 73, 'OLD'],
        ['committed', 'committed', 73, 'NEW']);
    for my $c (@cases) {
        my ($name, $f, $exit, $rev) = @$c;
        my $b = "$top/$name";
        my @seed = $name =~ /^(inactive-|absent-)/?('--fault', $name):();
        my $ok = eval {
            $check->($cmd->($b, 'fixture-seed', @seed) == 0, "$name seed writers and Git");
            if ($name eq 'backup') {
                for my $part (@backup_empty) {
                    make_path("$b/live/$part/deep");
                    write_file("$b/live/$part/deep/history", "excluded\n")
                }make_path("$b/live/local_data/log-extra");
                write_file("$b/live/local_data/log-extra/keep", "included\n");
                make_path("$b/live/local_data/dxhistory-archives");
                write_file("$b/live/local_data/dxhistory-archives/keep", "included\n");
            }
            my @opt = $name eq 'backup'?('--backup'):();
            $check->($cmd->($b, 'fixture-prepare', @opt) == 0, "$name prepare");
            if ($name eq 'normal') {
                my $l = "$b/.dxs-updater-live.lock";
                open my $lh, '>>', $l or fail('test lock');
                flock($lh, LOCK_EX|LOCK_NB) or fail('test lock acquire');
                $check->($cmd->($b, 'fixture-update') != 0,
                    'concurrent lock rejects second process');
                close $lh;
            }
            my @faults = length($f)?('--fault', $f):();
            my $rc = $cmd->($b, 'fixture-update', @faults);
            $check->($rc == $exit, "$name update exit=$rc expected=$exit");
            $check->($cmd->($b, 'fixture-recover') == 0 && $cmd->($b, 'fixture-recover') == 0,
                "$name independent recovery twice");
            my $live = "$b/live";
            $check->(read_file("$live/REVISION") eq "$rev\n", "$name active revision $rev");
            $check->(read_file("$live/data/upstream") eq "$rev DATA\n", "$name new data policy");
            $check->(read_file("$live/local/record") eq "site-local\n"
                && read_file("$live/local_data/name|with\nnewline") eq "content\x00\n"
                && !-e "$live/filter/upstream-only", "$name six trees preserved, strange name");
            my @a = lstat("$live/local/record");
            my @h = lstat("$live/filter/hardlink");
            $check->($a[1] == $h[1] && $a[0] == $h[0] && ($a[2]&07777) == 0640,
                "$name hardlinks and mode");
            $check->(-l "$live/local_data/external"
                && readlink("$live/local_data/external") eq '/not/a/real/path' && capture('stat',
                '-c',
                '%y', "$live/local_data/external") =~  /\.123456789 /,
                "$name symlink target and nanosecond mtime");
            my $jw = $json->decode(read_file("$b/.dxs-updater-live/journal.json"));
            $check->($jw->{state} eq ($rev eq 'NEW'?'COMMITTED':$name eq 'space-fail'?'STAGED':'ROLLED_BACK'), "$name durable state");
            if ($name eq 'backup') {
                $check->(-f "$b/.dxs-updater-live/backup/spider/REVISION"
                    && read_file("$b/.dxs-updater-live/backup/spider/REVISION") eq "OLD\n",
                    'additional backup retained');
                for my $part(@backup_empty) {
                    my $d = "$b/.dxs-updater-live/backup/spider/$part";
                    my @entries = glob("$d/*");
                    $check->(-d $d && !@entries, "backup $part empty");
                    $check->(-f "$live/$part/deep/history"
                        && -f "$b/.dxs-updater-live/old/$part/deep/history",
                        "$part preserved in active and rollback")
                }
                for my $part(qw(log-extra dxhistory-archives)) {
                    $check->(-f "$b/.dxs-updater-live/backup/spider/local_data/$part/keep",
                        "backup retains $part")
                }
            }
            if ($rev eq 'NEW') {
                $check->(-d "$b/.dxs-updater-live/old", "$name old retained")
            }
            if ($name eq 'crash-started' || $name eq 'start-fail' || $name eq 'verify-fail') {
                $check->(-d "$b/.dxs-updater-live/failed", "$name written candidate quarantined")
            }
            if (-f "$b/sqlite.enabled") {
                require DBI;
                require DBD::SQLite;
                my $db = DBI->connect("dbi:SQLite:dbname=$live/local_data/fixture.db", '', '',
                    {RaiseError => 1, PrintError => 0, sqlite_open_flags => 1});
                my ($rows) = $db->selectrow_array('SELECT count(*) FROM events');
                $db->disconnect;
                $check->($rows>0, "$name SQLite records readable")
            }
            local $base = $b;
            my $cfg = $json->decode(read_file("$b/services.json"));
            for my $r (@stop) {
                my $expected = $cfg->{$r} && !($r eq 'spider' && $name eq 'inactive-spider');
                $check->((fixture_pids($r)?1:0) == ($expected?1:0), "$name service policy $r")
            };
            1
        };
        my $err = $@;
        if (-f "$b/.fixture") {
            $cmd->($b, 'fixture-stop')
        }
        die $err unless $ok;
    }
    # Local changes and stale HEAD are pre-stop gates; workers stay running.
    my $b = "$top/local-changes";
    my $ok = eval{
        $check->($cmd->($b, 'fixture-seed') == 0, 'dirty fixture seed');
        write_file("$b/live/untracked-code", "local custom\n");
        $check->($cmd->($b, 'fixture-prepare') != 0, 'unapproved local changes blocked');
        $check->($cmd->($b, 'fixture-prepare', '--accept-local-changes') == 0,
            'explicit local changes acceptance');
        open my $fh, '>>', "$b/live/untracked-code" or fail('edit same dirty file');
        print {$fh} "changed\n";
        close $fh;
        $check->($cmd->($b, 'fixture-update') != 0,
            'changed contents with same dirty status blocked');
        local $base = $b;
        $check->(fixture_pids('spider') && fixture_pids('web') && fixture_pids('admin'),
            'preflight did not stop writers');
        1
    };
    my $e = $@;
    $cmd->($b, 'fixture-stop') if -f "$b/.fixture";
    die $e unless $ok;
    $b = "$top/unknown-writer";
    my $outside;
    $ok = eval{
        $check->($cmd->($b, 'fixture-seed') == 0, 'unknown writer fixture seed');
        $check->($cmd->($b, 'fixture-prepare') == 0, 'unknown writer prepare');
        $outside = fork();
        fail('unknown writer fork') unless defined $outside;
        if (!$outside) {
            open my $h, '>>', "$b/live/local_data/unmanaged.writer" or POSIX::_exit(10);
            $h->autoflush(1);
            print {$h} "ready\n";
            while (1) {
                print {$h} "external writer\n";
                sleep .1
            }
        }
        for (1..100) {
            last if -s "$b/live/local_data/unmanaged.writer";
            sleep .02
        }
        $check->($cmd->($b, 'fixture-update') != 0, 'unknown open-file writer blocked before stop');
        $check->(proc_info($outside), 'unrelated PID not signaled');
        local $base = $b;
        $check->(fixture_pids('spider') && fixture_pids('web') && fixture_pids('admin'),
            'managed services not stopped');
        1;
    };
    $e = $@;
    if ($outside) {
        kill 'TERM', $outside;
        waitpid($outside, 0)
    }
    $cmd->($b, 'fixture-stop') if -f "$b/.fixture";
    die $e unless $ok;
    $b = "$top/freshness";
    $ok = eval{
        $check->($cmd->($b, 'fixture-seed') == 0, 'freshness fixture seed');
        $check->($cmd->($b, 'fixture-prepare') == 0, 'freshness prepare');
        write_file("$b/repo/another-revision", "new remote revision\n");
        run('git', '-C', "$b/repo", 'add', '.');
        run('git', '-C', "$b/repo", 'commit', '-qm', 'advanced remote');
        $check->($cmd->($b, 'fixture-update') != 0, 'remote moved after staging; blocked');
        local $base = $b;
        $check->(fixture_pids('spider') && fixture_pids('web') && fixture_pids('admin'),
            'stale stage did not stop writers');
        $check->($cmd->($b, 'fixture-archive') == 0, 'stale stage archived without deletion');
        $check->($cmd->($b, 'fixture-prepare') == 0, 'new transaction after archive');
        $check->($cmd->($b, 'fixture-update') == 0, 'new HEAD activated after reprepare');
        1;
    };
    $e = $@;
    $cmd->($b, 'fixture-stop') if -f "$b/.fixture";
    die $e unless $ok;
    $b = "$top/fallback";
    $ok = eval{
        $check->($cmd->($b, 'fixture-seed') == 0, 'fallback fixture seed');
        run('git', 'clone', '-q', '--bare', '--no-hardlinks', "$b/repo", "$b/mirror");
        my $blob = capture('git', '-C', "$b/repo", 'rev-parse', 'HEAD:data/upstream');
        chomp $blob;
        my $obj = "$b/repo/.git/objects/".substr($blob, 0, 2).'/'.substr($blob, 2);
        unlink($obj) or fail('fixture corrupt primary object');
        $check->(defined remote_head("$b/repo", 'mojo'),
            'primary advertises branch despite missing object');
        $check->($cmd->($b, 'fixture-prepare') == 0, 'primary clone or fsck failure falls back');
        my $v = $json->decode(read_file("$b/.dxs-updater-live/journal.json"));
        $check->($v->{remote} eq "$b/mirror" && $v->{head} eq $v->{primary_head},
            'mirror matches advertised primary revision');
        $check->($cmd->($b, 'fixture-update') == 0, 'verified mirror activated');
        1;
    };
    $e = $@;
    $cmd->($b, 'fixture-stop') if -f "$b/.fixture";
    die $e unless $ok;
    print "TOTAL $count/$count PASS\nSAFETY fixture only; systemd and /spider untouched\n";
}

# Systemd integration harness. Runtime unit names are derived from the private
# fixture nonce, never from user input or from production unit names.

# ==========================================================================
# 14. Systemd integration tests
# ==========================================================================

sub systemd_fixture_select {
    return unless -f "$base/systemd-fixture.json";
    fail('systemd fixture requires root, dedicated base and systemd PID 1') unless $>==0 && $base =~ m{\A/root/dxs-updater-systemd-[A-Za-z0-9_-]+/[A-Za-z0-9_-]+\z} && optional_read('/proc/1/comm') eq "systemd\n";
    my $nonce = fixture_marker($base);
    my $cfg = $json->decode(read_file("$base/systemd-fixture.json"));
    fail('invalid systemd fixture config') unless ref($cfg) eq 'HASH'
        && ($cfg->{nonce}//'') eq $nonce
        && ref($cfg->{ports}) eq 'HASH' && ref($cfg->{exists}) eq 'HASH';
    for my $r (@stop) {
        fail('invalid fixture port') unless ($cfg->{ports}{$r}//0) =~ /\A\d+\z/
            && $cfg->{ports}{$r}>1023 && $cfg->{ports}{$r}<65536;
        fail('invalid fixture presence') unless defined($cfg->{exists}{$r})
            && $cfg->{exists}{$r} =~ /\A[01]\z/;
        $units{$r} = "dxs-updater-lab-$nonce-$r.service";
    }
    $systemd_fixture = $cfg;
}

sub systemd_unit_text {
    my ($r) = @_;
    my $p = $systemd_fixture->{ports}{$r};
    my $exe = realpath($^X);
    fail('unsafe Perl path') unless $exe =~ m{\A/[A-Za-z0-9_./-]+\z};
    return "[Unit]\nDescription=DXSpider updater isolated test $r\n[Service]\nType=simple\nUser=root\nGroup=root\nWorkingDirectory=$root\nExecStart=$exe $root/perl/systemd-fixture.pl $r $p\nKillMode=control-group\nTimeoutStopSec=10\nRestart=no\n";
}

sub systemd_fixture_guard {
    my ($r) = @_;
    fail('systemd fixture guard') unless $fixture && $systemd_fixture && $> == 0
        && $root eq "$base/live"
        && $units{$r} eq 'dxs-updater-lab-'.fixture_marker($base)."-$r.service";
    my $path = "/run/systemd/system/$units{$r}";
    my @s = lstat($path);
    fail('fixture unit file not owned/unchanged') unless @s && S_ISREG($s[2]) && $s[4] == 0
        && !($s[2]&0022) && read_file($path) eq systemd_unit_text($r);
    my $v = unit_info($r);
    fail('fixture effective unit is not the exact runtime unit')
        unless ($v->{FragmentPath}//'') eq $path
        && ($v->{ExecStart}//'') =~  /\Q$root\/perl\/systemd-fixture.pl\E/;
    # No drop-ins may change the fixture definition or introduce other actions.
    my $raw = capture('timeout', '10', 'systemctl', 'cat', $units{$r}, '--no-pager');
    $raw =~ s/\n+\z/\n/;
    fail('fixture effective definition changed') unless $raw eq "# $path\n".systemd_unit_text($r);
    return $v;
}

sub systemd_fixture_program {
    return <<'PERL';
use strict;use warnings;use IO::Socket::INET;use IO::Select;
my($role,$port)=@ARGV;die 'role' unless $role=~/\A(?:spider|web|admin)\z/;
my $s=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>$port,Proto=>'tcp',Listen=>8,ReuseAddr=>1) or die $!;
my $sel=IO::Select->new($s);$SIG{TERM}=sub{exit 0};$SIG{PIPE}='IGNORE';
open my $r,'<','REVISION' or die $!;my $rev=<$r>;close $r;chomp $rev;
while(1){open my $h,'>>',"local_data/$role.writer" or die $!;print {$h} "$rev $$\n";close $h or die $!;
 if($sel->can_read(.1)){my $c=$s->accept();next unless $c;$c->autoflush(1);if($role eq 'spider'){print {$c} 'login: '}else{my $title=$role eq 'admin'?'DXSpider Web Supervision':'DXSpider Web';my $body="<html><title>$title</title></html>";local $SIG{ALRM}=sub{die 'request timeout'};eval{alarm 2;while(<$c>){last if /^\r?\n$/}print {$c} "HTTP/1.0 200 OK\r\nContent-Length: ".length($body)."\r\n\r\n$body";};alarm 0;}close $c;}
}
PERL
}

sub systemd_fixture_seed_units {
    my ($initial, $exists) = @_;
    my @held;
    my %ports;
    for my $r (@stop) {
        my $sock = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1,
            Proto => 'tcp') or fail('fixture port allocation');
        $ports{$r} = $sock->sockport;
        push @held, $sock
    }
    write_file("$base/systemd-fixture.json", $json->encode({nonce => fixture_marker($base),
        ports => \%ports, exists => $exists}));
    systemd_fixture_select();
    for my $r (@stop) {
        my $v = unit_info($r);
        fail('fixture unit name collision') unless $v->{ok} && ($v->{LoadState}//'') eq 'not-found'
            && unit_stopped($v) && !exists_path("/run/systemd/system/$units{$r}");
    }
    for my $r (@stop) {
        next unless $exists->{$r};
        write_file("/run/systemd/system/$units{$r}", systemd_unit_text($r));
    }
    close $_ for @held;
    run('timeout', '30', 'systemctl', 'daemon-reload');
    for my $r (@start) {
        next unless $initial->{$r};
        systemd_fixture_guard($r);
        run('timeout', '30', 'systemctl', 'start', $units{$r});
        my $ready = 0;
        for (1..40) {
            my $v = unit_info($r);
            if (eval{
                probe_unit($r, read_probes()->{$r}, $v);
                1
            }) {
                $ready = 1;
                last
            }
            sleep .25
        }
        fail("fixture service $r not ready") unless $ready;
    }
}

sub systemd_fixture_cleanup {
    systemd_fixture_select();
    my @created;
    for my $r (@stop) {
        next unless $systemd_fixture->{exists}{$r};
        my $path = "/run/systemd/system/$units{$r}";
        next unless exists_path($path);
        my @s = lstat($path);
        fail('cleanup refuses changed unit file') unless @s && S_ISREG($s[2]) && $s[4] == 0
            && !($s[2]&0022) && read_file($path) eq systemd_unit_text($r);
        my $v = unit_info($r);
        if (!($v->{ok} && ($v->{LoadState}//'') eq 'not-found' && unit_stopped($v))) {
            systemd_fixture_guard($r);
            run('timeout', '30', 'systemctl', 'stop', $units{$r});
            fail('fixture service not stopped') unless unit_stopped(unit_info($r));
        }
        push @created, $path;
    }
    for my $p (@created) {
        unlink $p or fail("remove fixture unit $p: $!")
    }
    run('timeout', '30', 'systemctl', 'daemon-reload') if @created;
    print "SYSTEMD FIXTURE CLEANUP OK $base\n";
}

sub systemd_selftest {
    fail('requires actual systemd PID 1, root, /run/systemd/system; no service actions performed')
        unless $> == 0 && optional_read('/proc/1/comm') eq "systemd\n" && -d '/run/systemd/system'
        && !-l '/run/systemd/system';
    my $top = $base;
    fail('use new /root/dxs-updater-systemd-UNIQUE base') unless $top =~ m{\A/root/dxs-updater-systemd-[A-Za-z0-9_-]+\z} && !exists_path($top);
    mkdir($top, 0700) or fail('systemd test base');
    my $count = 0;
    my $check = sub{
        my ($ok, $what) = @_;
        fail("TEST $what") unless $ok;
        print "PASS $what\n";
        ++$count
    };
    my $cmd = sub{
        my ($m, @a) = @_;
        system {$^X} $^X, $script, '--mode', $m, '--base', $base, @a;
        return $? & 127 ? 128+($? & 127) : $?>>8
    };
    for my $case ('normal', 'inactive-absent', 'verify-fail', 'crash-after-rename') {
        local $base = "$top/$case";
        my $ok = eval{
            $check->($cmd->('fixture-seed', '--fault', 'systemd-fixture') == 0, "$case seed");
            $fixture = 1;
            $root = validate_root("$base/live", 0);
            $systemd_fixture = undef;
            my %exists = (admin => 1, web => 1, spider => 1);
            my %initial = (admin => 1, web => 0, spider => 1);
            if ($case eq 'inactive-absent') {
                $exists{admin} = 0;
                $initial{admin} = 0;
                $initial{spider} = 0;
            }
            systemd_fixture_seed_units(\%initial, \%exists);
            $check->(1, "$case real systemd initial states and probes");
            $check->($cmd->('fixture-prepare') == 0, "$case Git prepare");
            my @fault = $case eq 'verify-fail'?('--fault',
                'verify'):$case eq 'crash-after-rename'?('--fault', 'new-renamed'):();
            my $expected = $case eq 'verify-fail'?1:$case eq 'crash-after-rename'?73:0;
            $check->($cmd->('fixture-update', @fault) == $expected, "$case update exit $expected");
            my $journal = "$base/.dxs-updater-live/journal.json";
            my $v = $json->decode(read_file($journal));
            if ($case eq 'crash-after-rename') {
                $check->($v->{state} eq 'ACTIVATING' && -d "$base/.dxs-updater-live/old",
                    "$case interruption at rename");
            }
            $check->($cmd->('fixture-recover') == 0 && $cmd->('fixture-recover') == 0,
                "$case independent recovery twice");
            $v = $json->decode(read_file($journal));
            my $new = $expected == 0;
            my $rev = $new?'NEW':'OLD';
            $check->($v->{state} eq ($new?'COMMITTED':'ROLLED_BACK')
                && read_file("$root/REVISION") eq "$rev\n", "$case final revision and journal");
            $check->(read_file("$root/local/record") eq "site-local\n"
                && read_file("$root/data/upstream") eq "$rev DATA\n",
                "$case persistent and upstream data");
            for my $r (@stop) {
                my $u = unit_info($r);
                my $want = $new?($exists{$r} && ($r ne 'spider' || $initial{$r})):$initial{$r};
                if (!$exists{$r}) {
                    $check->(($u->{LoadState}//'') eq 'not-found', "$case $r remains absent");
                    next
                }
                $check->($want?($u->{confirmed} && eval{
                    probe_unit($r, read_probes()->{$r}, $u);
                    1
                }):unit_stopped($u), "$case $r final service policy");
            }
            if ($case eq 'verify-fail') {
                $check->(-d "$base/.dxs-updater-live/failed"
                    && ($v->{reconciliation}{status}//'') eq 'REVIEW_REQUIRED',
                    "$case written candidate retained");
            }
            1;
        };
        my $err = $@;
        my $clean = eval{
            systemd_fixture_cleanup() if -f "$base/systemd-fixture.json";
            1
        };
        my $ce = $@;
        die "$err$ce" unless $ok && $clean;
    }
    print "SYSTEMD TOTAL $count/$count PASS\nSAFETY only nonce-named runtime units and isolated fixture trees; production activation disabled\n";
}


# ==========================================================================
# 15. Git preparation validation
# ==========================================================================

sub git_prepare_check {
    fail('Git check requires root-owned source on reference host') unless $> == 0 && $owner == 0;
    fail('new dedicated /root/dxs-updater-git-UNIQUE required') unless $base =~ m{\A/root/dxs-updater-git-[A-Za-z0-9_-]+\z} && !exists_path($base);
    fail('Git check must be outside source and on same filesystem') if under($base, $root)
        || (stat(dirname($base)))[0] != (stat($root))[0];
    tools_check();
    no_mounts($root);
    capacity(1);
    mkdir($base, 0700) or fail('Git check mkdir');
    $work = $base;
    configure_tmp();
    $j = {kind => 'git-only-validation', root => $root, branch => $branch, version => VERSION};
    checkpoint('PLANNED');
    stage_git();
    clean_git("$work/candidate", $j->{head}, $branch, $j->{remote});
    fail('Git check version metadata changed')
        unless $json->encode(version_identity("$work/candidate")) eq $json->encode($j->{git_version_metadata});
    fail('Git check HEAD changed') unless same(remote_head($j->{remote}, $branch), $j->{head});
    $j->{candidate_sha} = manifest("$work/candidate", '.');
    sync_tree("$work/candidate");
    checkpoint('STAGED');
    print "GIT PREPARE CHECK PASS $j->{head} $j->{remote}\nCANDIDATE $work/candidate\nSAFETY Git-only evidence; no runtime copy, service actions or production authorization\n";
}

# Operator interface. The existing engine remains the only mutation path.
# This release is deliberately a preview: no service stop/start or restore.
my ($ui_log, $ui_console, $ui_logpath);
my %ui_label = (spider => 'DXSpider', web => 'DXWeb', admin => 'DXWeb Admin');

# ==========================================================================
# 16. Operator interface helpers and discovery
# ==========================================================================

sub ui_safe {
    my ($s) = @_;
    $s //= '';
    $s =~ s/([\x00-\x1f\x7f])/sprintf('\\x%02x',ord($1))/ge;
    return $s
}

sub ui_say {
    my ($s) = @_;
    if ($ui_console) {
        print {$ui_console} "$s\n"
    } else {
        print "$s\n"
    }
}

sub ui_screen_enabled {
    return -t STDIN && -t STDOUT && ($ENV{TERM}//'') ne '' && ($ENV{TERM}//'') ne 'dumb';
}

sub ui_section {
    my ($label, $clear) = @_;
    $clear = 1 unless defined $clear;
    print {$ui_log} "\n=== SCREEN: $label ===\n" if $ui_log;
    if ($clear && ui_screen_enabled()) {
        print "\e[2J\e[H", ("=" x 62), "\n DXSpider Manager ", VERSION, "\n", ("=" x 62), "\n";
        print LIVE_ENABLED ? " LIVE\n" : " PREVIEW - production actions disabled\n";
        my ($os) = optional_read('/etc/os-release') =~ /^PRETTY_NAME="?([^"\n]+)"?$/m;
        print " OS: ", ui_safe($os//'unknown'), " | Perl: $^V\n";
    }
    print "\n", ("-" x 62), "\n $label\n", ("-" x 62), "\n\n";
}

sub ui_event {
    my ($message) = @_;
    return unless $ui_console;
    print {$ui_log} "EVENT ", time, " $message\n" if $ui_log;
    if ($message =~  /^\[(?: OK |FAIL|WARNING|SKIPPED)\]/) {
        ui_result($message);
    }  else {
        ui_say("    $message");
    }
}

# A single console convention for visible results, including engine events.
sub ui_result {
    my ($message) = @_;
    print {$ui_log} "RESULT ", time, " $message\n" if $ui_log;
    my $styled = $message;
    my $terminal = $ui_console ? (-t $ui_console && ($ENV{TERM}//'') ne 'dumb'
        && length($ENV{TERM}//'')) : ui_screen_enabled();
    if ($terminal && !exists $ENV{NO_COLOR}) {
        my $color = $message =~ /^\[ OK \]/?32:$message =~ /^\[FAIL\]/?31:$message =~ /^\[WARNING\]/?33:36;
        $styled = "\e[${color}m$message\e[0m";
    }
    ui_say("\n  $styled\n");
}

sub ui_ask {
    my ($prompt, $default) = @_;
    print $prompt, defined($default)?" [$default]":'', ': ';
    my $s = <STDIN>;
    return undef unless defined $s;
    chomp $s;
    $s =~ s/\r$//;
    return length($s)?$s:$default;
}

sub ui_yes {
    my ($prompt, $default) = @_;
    while (1) {
        my $a = ui_ask($prompt, $default?'Y/n':'y/N');
        return undef unless defined $a;
        return $default if $a eq 'Y/n' || $a eq 'y/N';
        return 1 if $a =~ /\A(?:y|yes)\z/i;
        return 0 if $a =~ /\A(?:n|no)\z/i;
        print "Please enter y or n.\n"
    }
}

sub ui_installation {
    my ($p) = @_;
    return undef unless defined($p)&&$p=~m{^/} && $p!~/[\x00-\x1f\x7f]/;
    my $r = realpath($p);
    return undef unless defined($r) && $r ne '/' && -f "$r/perl/cluster.pl"
        && -f "$r/local/DXVars.pm"
        && !-l "$r/perl" && !-l "$r/perl/cluster.pl";
    return $r
}

# Discovery is evidence-based: exact conventional paths, actual account
# homes, explicit paths, a running cluster.pl, or a configured Spider unit.
# Never recurse into arbitrary project, backup or export.
my %ui_discovery_reason;
sub ui_standard_paths {
    my @p = ('/spider', '/root/spider', '/opt/spider', '/srv/spider', '/usr/local/spider');
    setpwent();
    while (my @pw = getpwent()) {
        my $h = $pw[7]//'';
        push @p,"$h/spider" if $h=~m{^/home/[^/]+$}
    }endpwent();
    return @p;
}

sub ui_unit_paths {
    if (LIVE_ENABLED) {
        my ($ok, $records) = service_catalogue();
        if ($ok) {
            return map {$_->[0]} grep {$_->[1] eq 'spider'} map {service_entry_points($_)} @$records;
        }
    }
    my ($ok, $list) = capture_status('timeout', '10', 'systemctl', 'list-unit-files',
        '--type=service',
        '--no-legend', '--no-pager');
    return () unless $ok;
    my %names = ($units{spider} => 1);
    for my $line(split /\n/, $list) {
        my ($n) = $line =~ /^\s*([A-Za-z0-9_.@-]+\.service)\s/;
        next unless defined($n) && $n =~ /dxspider/i && $n !~ /@\.service$/;
        $names{$n} = 1
    }
    my @paths;
    for my $name(sort keys %names) {
        my ($good, $o) = capture_status('timeout', '10', 'systemctl', 'show', $name, '--no-pager',
            '--property=LoadState,ExecStart,WorkingDirectory');
        next unless $good && $o =~ /^LoadState=loaded$/m;
        my ($exec) = $o =~ /^ExecStart=(.*)$/m;
        my ($cwd) = $o =~ /^WorkingDirectory=(.*)$/m;
        next unless defined($exec);
        while($exec=~m{(?:^|[\s=;])(/[^\s;{}]+?)/perl/cluster\.pl(?=[\s;\}]|$)}g) {
            push @paths, $1
        }
        if(defined($cwd)&&$exec=~m{(?:^|[\s=;])(?:\./)?cluster\.pl(?=[\s;\}]|$)}) {
            push @paths,$cwd,dirname($cwd) if $cwd=~m{^/}
        }
    }
    return @paths;
}

sub ui_discover {
    my (@extra) = @_;
    %ui_discovery_reason = ();
    my $add = sub{
        my ($p, $reason) = @_;
        my $r = ui_installation($p);
        return unless defined $r;
        $ui_discovery_reason{$r}{$reason} = 1;
        return $r
    };
    for my $p(ui_standard_paths()) {
        $add->($p, 'standard location')
    }
    $add->($installation, 'requested/default path');
    for my $p(@extra) {
        $add->($p, 'explicit scan path')
    }
    for my $p(ui_unit_paths()) {
        $add->($p, 'configured systemd unit')
    }
    for my $pid(all_pids()) {
        my $p = proc_info($pid) or next;
        next unless manual_candidate($p);
        my $a = $p->{argv}[-1];
        if($a=~m{^/.*?/perl/cluster\.pl$}) {
            $add->(dirname(dirname($a)), 'running DXSpider')
        } else {
            $add->($p->{cwd}, 'running DXSpider');
            $add->(dirname($p->{cwd}),'running DXSpider') if $p->{cwd}=~m{/perl$}
        }
    }
    return sort {($ui_discovery_reason{$b}{'running DXSpider'}//0)<=>($ui_discovery_reason{$a}{'running DXSpider'}//0) || ($a eq '/spider'?0:1)<=>($b eq '/spider'?0:1) || $a cmp $b} keys %ui_discovery_reason;
}

sub ui_choose {
    my (@r) = @_;
    return ui_choose_for('update', @r);
}

# A missing active tree is a valid recovery target only if its protected
# transaction journal identifies it. Never use a random missing path.
sub ui_recovery_path {
    my ($p) = @_;
    return undef unless defined $p;
    my $r = ui_installation($p);
    return $r if defined $r;
    if ($p eq '/spider' && -l $p) {
        my $target = readlink($p);
        return undef unless defined($target) && $target=~m{^/};
        $p = $target;
    }
    my $ok = eval {
        validate_root($p, 1);
        fail('active path exists but is not a configured node') if exists_path($p);
        my $layout = transaction_layout($p, undef);
        my $w = $layout->{work};
        protected_ancestors($w);
        my $v = protected_json("$w/journal.json");
        fail('no interrupted transaction for this path') unless ($v->{root}//'') eq $p
            && ($v->{state}//'') =~ /\A(?:STOPPING|QUIESCENT|COPYING|BACKING_UP|PREPARED|ACTIVATING|STARTING|VERIFIED|ROLLING_BACK|RECOVERY_REQUIRED)\z/ && same(ident($layout->{home}?"$w/trees/old":"$w/old"), $v->{old_id});
        1;
    };
    return $ok?$p:undef;
}

sub ui_choose_for {
    my ($action, @r) = @_;
    my $prompt = $action eq 'update'?'Select DXSpider installation to update':$action eq 'recovery'?'Select DXSpider installation for recovery':'Select DXSpider installation to inspect';
    while (1) {
        print "\nDXSpider installation candidates found: ", scalar(@r), "\n";
        for my $i(0..$#r) {
            my $p = $r[$i];
            my $reason = $ui_discovery_reason{$p}{'running DXSpider'}?'running':$ui_discovery_reason{$p}{'configured systemd unit'}?'systemd configured':$ui_discovery_reason{$p}{'interrupted transaction'}?'interrupted transaction':'';
            print '  [', $i+1, '] ', ui_safe($p), length($reason)?" ($reason)":'', "\n"
        }
        print "  [P] Enter another installation path\n  [Q] Return / quit\n";
        my $a = ui_ask($prompt, @r == 1?'1':undef);
        return undef if !defined($a) || $a =~ /^q$/i;
        return $r[$a-1] if $a =~ /\A[1-9]\d*\z/ && $a <= @r;
        if ($a =~ /^p$/i) {
            my $p = ui_ask('Absolute installation path', undef);
            return undef unless defined $p;
            my $r = $action eq 'recovery'?ui_recovery_path($p):ui_installation($p);
            return $r if $r;
            print "Not a configured DXSpider installation (requires perl/cluster.pl and local/DXVars.pm).\n"
        } else {
            print "Invalid selection.\n"
        }
    }
}

# The pending-install pointer is intentionally outside the installation and
# its staging area. It is never placed in an account-writable HOME.
sub manager_state_directory {
    my ($create) = @_;
    my $p = '/var/log/dxs-manager';
    fail('root required for manager operations') unless $> == 0;
    protected_ancestors(dirname($p));
    if (!exists_path($p)) {
        return undef unless $create;
        mkdir($p, 0700) or fail("mkdir $p: $!");
        sync_dir(dirname($p));
    }
    my @s = lstat($p);
    fail('unsafe manager state directory') unless @s && S_ISDIR($s[2]) && $s[4] == 0
        && !($s[2]&0077);
    return $p;
}

sub protected_ancestors {
    my ($p) = @_;
    while (1) {
        my @s = lstat($p);
        fail("untrusted protected directory $p") unless @s && S_ISDIR($s[2]) && $s[4] == 0
            && !($s[2]&0022);
        last if $p eq '/';
        $p = dirname($p);
    }
    return 1;
}

sub install_global_lock {
    my ($dir) = @_;
    protected_ancestors($dir);
    my $path = "$dir/install.lock";
    sysopen my $guard, $path, O_RDWR|O_CREAT|O_NOFOLLOW, 0600 or fail('install lock');
    my @st = stat($guard);
    fail('unsafe install lock') unless @st && S_ISREG($st[2]) && $st[3] == 1 && $st[4] == 0
        && !($st[2]&0077);
    fail('another installation or recovery is in progress') unless flock($guard, LOCK_EX|LOCK_NB);
    return $guard;
}

sub protected_json {
    my ($path) = @_;
    my @st = lstat($path);
    fail("unsafe durable record $path") unless @st && S_ISREG($st[2]) && $st[3] == 1 && $st[4] == 0
        && !($st[2]&0077) && $st[7]<1048576;
    my $v = $json->decode(read_file($path));
    fail('invalid durable record') unless ref($v) eq 'HASH';
    return $v;
}

sub install_pending_read {
    my ($dir) = @_;
    return undef unless defined $dir;
    protected_ancestors($dir);
    my $path = "$dir/pending-install.json";
    return undef unless exists_path($path);
    my $r = protected_json($path);
    fail('invalid pending installation pointer') unless ($r->{version}//0) == 1
        && ($r->{operation}//'') eq 'install' && ($r->{workspace_id}//'') =~ /\A[0-9]+:[0-9]+\z/;
    path_check($r->{destination}//'');
    path_check($r->{workspace}//'');
    fail('invalid installation workspace name')
        unless basename($r->{workspace}) =~ /\A\.dxs-install-[0-9]+-[0-9a-f]{12}\z/;
    protected_ancestors($r->{workspace});
    fail('pending workspace identity changed') unless same(ident($r->{workspace}),
        $r->{workspace_id});
    my @s = lstat($r->{workspace});
    fail('pending workspace has unsafe mode') if $s[2]&0066;
    return $r;
}

# Caller must hold install_global_lock throughout registration and publication.
sub install_pending_register {
    my ($dir, $prepared, $destination) = @_;
    fail('another installation requires recovery') if install_pending_read($dir);
    my $w = $prepared->{path};
    protected_ancestors($w);
    fail('installation workspace not private') if (lstat($w))[2]&0077;
    fail('invalid new installation workspace')
        unless basename($w) =~ /\A\.dxs-install-[0-9]+-[0-9a-f]{12}\z/;
    my $p = protected_json("$w/install-plan.json");
    fail('cannot register an unverified installation plan') unless ($p->{state}//'') eq 'STAGED'
        && ($p->{destination}//'') eq $destination
        && ($p->{operation}//'') eq 'install-preparation';
    my $record = {version => 1, operation => 'install', workspace => $w, workspace_id => ident($w),
        destination => $destination, created => time};
    atomic_write("$dir/pending-install.json", $json->encode($record)."\n");
    return $record;
}

sub install_pending_plan {
    my ($dir, $alias) = @_;
    my $r = install_pending_read($dir) or return;
    my $w = $r->{workspace};
    my $p = protected_json("$w/install-plan.json");
    fail('pending plan does not match pointer') unless ($p->{version}//0) == 1
        && ($p->{operation}//'') eq 'install-preparation'
        && ($p->{destination}//'') eq $r->{destination};
    fail('unexpected installation recovery state')
        unless ($p->{state}//'') =~ /\A(?:STAGED|ASSIGNING|ACTIVATING|PUBLISHED|DATABASE|DATABASE_READY|SERVICE_WRITING|SERVICE_PUBLISHED|SERVICE_STARTING|SERVICE_ENABLING|SERVICE_WITHDRAWING|INSTALL_COMMITTED|FAILED_RETAINED)\z/;
    if ($p->{state} ne 'STAGED' && !($p->{state} eq 'FAILED_RETAINED'
        && !defined($p->{candidate_id}))) {
        fail('invalid pending publication identity')
            unless ($p->{candidate_id}//'') =~ /\A[0-9]+:[0-9]+\z/ && ($p->{uid}//0)>0
            && ($p->{gid}//0)>0 && ($p->{alias}//'') eq $alias;
        my $layout = transaction_layout($p->{destination}, $p->{uid});
        fail('pending installation layout changed')
            unless $layout->{home} == ($p->{home_layout}//0);
        protected_ancestors(dirname($alias));
        if ($p->{home_layout} && $p->{state} ne 'ASSIGNING' && $p->{state} ne 'FAILED_RETAINED') {
            install_home_data_check($w, $p);
        }
        fail('recovery filesystem mismatch')
            unless (stat($w))[0] == (stat(dirname($p->{destination})))[0];
    }
    return ($r, $p);
}

# Do not discard the plan or its retained trees. Only remove the pointer to a
# verified terminal state, after syncing the journal.
sub install_pending_clear {
    my ($dir, $alias) = @_;
    my ($r, $p) = install_pending_plan($dir, $alias);
    return unless $r;
    fail('pending installation is not terminal')
        unless $p->{state} =~ /\A(?:INSTALL_COMMITTED|FAILED_RETAINED)\z/;
    my $dest = $p->{destination};
    my $w = $r->{workspace};
    if ($p->{state} eq 'INSTALL_COMMITTED') {
        fail('committed installation identity changed') unless same(ident($dest),
            $p->{candidate_id})
            && (realpath($alias)//'') eq $dest;
    } elsif (defined($p->{candidate_id})) {
        my @saved = grep {exists_path($_)} ("$w/failed-install", "$w/trees/failed-install");
        fail('failed installation identity changed') unless @saved == 1 && same(ident($saved[0]),
            $p->{candidate_id}) && !exists_path("$w/candidate")
            && !exists_path("$w/trees/candidate");
        fail('failed tree still active') if exists_path($dest) && same(ident($dest),
            $p->{candidate_id});
    } else {
        fail('unused candidate missing') unless -d "$w/candidate" && !-l "$w/candidate";
    }
    unlink("$dir/pending-install.json") or fail('cannot clear pending installation pointer');
    sync_dir($dir);
    return 1;
}

# Recover from a separate process using only durable evidence, not the
# previous process' Perl globals. The caller owns the global install lock.
sub install_recover_registered {
    my ($dir, $alias) = @_;
    my ($r, $p) = install_pending_plan($dir, $alias);
    return 'NO_PENDING' unless $r;
    $work = $r->{workspace};
    $root = $p->{destination};
    ($owner, $group) = @$p{qw(uid gid)};
    $fixture = 0;
    $home_fs = $p->{home_layout}//0;
    if ($p->{state} eq 'STAGED') {
        # No publication intent exists. The complete staged tree is retained.
        fail('staged candidate missing') unless -d "$work/candidate" && !-l "$work/candidate";
        install_checkpoint($p, 'FAILED_RETAINED');
    } elsif ($p->{state} eq 'ASSIGNING') {
        # A crash during chown/chmod may leave a partly assigned candidate.
        # No live rename or alias creation has been authorized yet.
        fail('unexpected destination or alias after assignment') if exists_path($root)
            || exists_path($alias);
        my @locations = grep {exists_path($_)} ("$work/candidate", "$work/failed-install",
            "$work/trees/candidate", "$work/trees/failed-install");
        fail('ambiguous assignment recovery') unless @locations == 1 && same(ident($locations[0]),
            $p->{candidate_id});
        my $src = $locations[0];
        my $failed = dirname($src).'/failed-install';
        require_no_unknown_writers({}, $src, $failed);
        if ($src ne $failed) {
            if ((lstat($work))[2]&0077) {
                install_home_data_check($work, $p);
                fail('unexpected exposed assignment path') unless $src eq "$work/trees/candidate";
                owner_file_call(sub {move_tree($src, $failed); 1});
            } else {
                # Root-private staging: the account cannot access these paths.
                move_tree($src, $failed);
            }
        }
        install_checkpoint($p, 'FAILED_RETAINED');
    } elsif ($p->{state} =~ /\ASERVICE_/) {
        install_recover_service($p);
    } elsif ($p->{state} =~ /\A(?:ACTIVATING|PUBLISHED|DATABASE|DATABASE_READY)\z/) {
        # No service publication intent. Never touch a pre-existing unit.
        for my $role (@start) {
            my $v = unit_info($role);
            fail('unit state ambiguous during installation recovery') unless $v->{ok}
                && ($v->{LoadState}//'') eq 'not-found' && unit_stopped($v);
        }
        install_retain_failed_publication($p);
    }
    install_pending_clear($dir, $alias);
    return $p->{state};
}

sub ui_open_log {
    return if $ui_log;
    my ($action) = @_;
    $action = 'update' unless defined($action) && $action =~  /\A(?:install|update|restore)\z/;
    my $p = manager_state_directory(1);
    $ui_logpath = "$p/$action-".POSIX::strftime('%Y%m%d-%H%M%S',
        localtime).'-'.substr(random_token(),
        0, 12).'.log';
    sysopen($ui_log, $ui_logpath, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,
        0600) or fail("create log: $!");
    $ui_log->autoflush(1);
    print {$ui_log} "DXSpider Manager ", VERSION, " action=$action started=", time,
        " installation=",
        ui_safe($root), "\n";
    print "Technical log: $ui_logpath\n";
}

sub ui_step {
    my ($label, $cb) = @_;
    print "  $label ...\n" if $label =~ /Preparing|Checking remote|Calculating|Rechecking/;
    print {$ui_log} "\n=== $label ===\n";
    # Redirect actual file descriptors so subprocess output, including Git's
    # diagnostics, is captured as well. Preserve interactive console for events.
    open my $out, '>&', \*STDOUT or fail('save stdout');
    open my $err, '>&', \*STDERR or fail('save stderr');
    $out->autoflush(1);
    STDOUT->flush;
    STDERR->flush;
    open STDOUT, '>&', $ui_log or fail('redirect stdout');
    open STDERR, '>&', $ui_log or fail('redirect stderr');
    STDOUT->autoflush(1);
    STDERR->autoflush(1);
    $ui_console = $out;
    my ($result, $e);
    my $ok = eval{
        $result = $cb->();
        1
    };
    $e = $@;
    print {$ui_log} $e unless $ok;
    STDOUT->flush;
    STDERR->flush;
    open STDOUT, '>&', $out or die 'restore stdout';
    open STDERR, '>&', $err or die 'restore stderr';
    STDOUT->autoflush(1);
    STDERR->autoflush(1);
    undef $ui_console;
    ui_result($ok ? "[ OK ] $label" : "[FAIL] $label (see technical log)");
    return($ok, $result);
}

sub ui_revision {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {ui_revision(@args)});
    }
    my ($r) = @_;
    my %v = (branch => 'unknown', head => 'unknown', describe => 'unavailable');
    return \%v unless -d "$r/.git" && !-l "$r/.git";
    my ($ok, $s) = capture_status(git($r, 'symbolic-ref', '--short', '-q', 'HEAD'));
    chomp $s;
    $v{branch} = $ok?$s:'detached';
    ($ok, $s) = capture_status(git($r, 'rev-parse', 'HEAD'));
    chomp $s;
    $v{head} = $s if $ok;
    ($ok, $s) = capture_status(git($r, 'describe', '--long'));
    chomp $s;
    $v{describe} = $s if $ok;
    return \%v;
}

sub ui_ports {
    my ($known) = @_;
    my $o = listener_owners($known);
    my %p;
    for my $l(tcp_listeners()) {
        next unless $o->{$l->{inode}} && loopback_candidate($l, $l->{port});
        $p{$l->{port}} = 1
    }
    return sort {$a<=>$b} keys %p
}

# ==========================================================================
# 17. Operator service and capacity presentation
# ==========================================================================

sub ui_services {
    my ($u, $inventory_blocks) = service_inventory();
    my $known = known_unit_processes($u);
    my @manual;
    my @other;
    my @custom;
    # Never infer a restart contract from cwd alone. Match candidate for display;
    # the engine's manual_contract will still verify it before any future action.
    for my $q(unknown_writers($known, $root)) {
        my $p = proc_info($q->[0]) or next;
        if (manual_candidate($p) && under($p->{cwd}, $root)) {
            push @manual, $p
        } else {
            push @other, "PID $q->[0] ($q->[1])"
        }
    }
    my %s;
    my @block = @$inventory_blocks;
    for my $r(@start) {
        my $v = $u->{$r};
        my $load = $v->{LoadState}//'unknown';
        my $active = $v->{ActiveState}//'unknown';
        my $label = $ui_label{$r};
        my $o = {state => 'Unknown', after => 'BLOCKED', unit => $v->{name}, ports => []};
        if ($load eq 'loaded' && !$v->{associated}) {
            $o->{state} = 'Unit belongs to another or unknown installation';
            push @block, "$label unit is not associated with selected tree"
        }
        elsif (!$v->{ok}) {
            $o->{state} = 'systemd status unavailable';
            push @block, "$label unit inventory unavailable"
        }
        elsif ($r eq 'spider' && @manual) {
            if (@manual == 1 && $active ne 'active') {
                $o->{state} = "Running manually (PID $manual[0]{pid})";
                $o->{after} = 'Restart manually (requires confirmed launch contract)';
                $o->{manual} = 1;
                $o->{manual_unit_guard} = {load => $v->{LoadState}, sha => $v->{unit_sha},
                    identity => unit_identity($v)};
                $o->{process} = $manual[0];
                $o->{ports} = [ui_ports({$manual[0]{pid} => $manual[0]{start}})]
            } else {
                $o->{state} = 'Ambiguous manual/systemd processes';
                push @block, 'DXSpider process identity ambiguous'
            }
        }
        elsif ($load eq 'not-found') {
            $o->{state} = $r eq 'spider'?'Stopped / manual start pending':'Service not installed';
            $o->{after} = $r eq 'spider'?'Remain stopped; operator starts manually':'SKIPPED (no unit)'
        }
        elsif ($load eq 'loaded' && unit_definition_ok($v) && (($active eq 'active'
            && $v->{confirmed})
            || ($active eq 'inactive' && unit_stopped($v)))) {
            $o->{state} = $active eq 'active'?"Running (systemd, PID $v->{MainPID})":'Stopped (systemd)';
            $o->{after} = $r eq 'spider'
                && $active ne 'active'?'Remain stopped':$active eq 'active'?'Restart existing service':'Start existing service';
            $o->{unit_info} = $v;
            $o->{inactive} = 1 if $active eq 'inactive';
            if ($v->{confirmed}) {
                $o->{ports} = [ui_ports(unit_members($v))];
            }
        }
        else {
            $o->{state} = "Unverified unit ($load/$active)";
            push @block, "$label unit state not verified"
        }
        $s{$r} = $o;
    }
    push @block, 'Other process references: '.join(', ',
        @other).' (leave installation directories before updating)' if @other;
    return {roles => \%s, block => \@block, custom => \@custom};
}

sub ui_service_table {
    my ($s) = @_;
    for my $r(@start) {
        my $x = $s->{roles}{$r};
        my $state = $x->{state};
        $state =~ s/ \(PID \d+\)//;
        $state =~ s/\(systemd, PID \d+\)/(systemd)/;
        printf "  %-14s %s\n", $ui_label{$r}, $state;
        print "                 Unit: $x->{unit}\n" if $x->{unit_info} && $x->{unit};
        print "                 After update: $x->{after}\n"
    }
    for my $b(@{$s->{block}}) {
        print {$ui_log} "SERVICE BLOCK: $b\n" if $ui_log;
        if ($b =~ /^Other process references:/) {
            print "\n  BLOCK: Other processes are using the installation.\n  Leave its directories in other terminals before updating.\n  Process details are in the technical log.\n"
        } else {
            print "  BLOCK: $b\n"
        }
    }
    print {$ui_log} $json->encode($s), "\n" if $ui_log;
}

sub ui_probe_preview {
    my ($s) = @_;
    my %defaults = (spider => 9300, web => 7380, admin => 7381);
    my %probes;
    for my $r(@start) {
        my $o = $s->{roles}{$r};
        next unless $o->{manual} || $o->{unit_info};
        if ($o->{inactive}) {
            next if $r eq 'spider';
            # No live socket exists: obtain an explicit endpoint for post-start
            # verification rather than claim that a stopped service was probed.
            my $port = ui_ask("$ui_label{$r} port for verification after startup (0 to skip)",
                $defaults{$r});
            if (defined($port) && $port =~ /\A[1-9]\d{0,4}\z/ && $port <= 65535) {
                $probes{$r} = {type => 'title', port => 0+$port, path => '/', status => 200,
                    expect => $r eq 'web'?'DXSpider Web':'DXSpider Web Supervision'};
                print "  $ui_label{$r}: functional verification deferred until startup.\n";
            } else { print "  $ui_label{$r}: no verification port; activation would be blocked.\n";
            }
            next;
        }
        if ($o->{manual}) {
            unless (ui_yes("Confirm manual launch from $root/perl using ./cluster.pl for the plan?",
                0)) {
                print "  Manual restart not approved; activation would be blocked.\n";
                next
            }
        }
        my @ports = @{$o->{ports}};
        unless (@ports) {
            print "  $ui_label{$r}: no observed local listener; activation would be blocked.\n";
            next
        }
        my $def = (grep {$_ == $defaults{$r}} @ports)?$defaults{$r}:@ports == 1?$ports[0]:undef;
        my $port = $def;
        while (!defined($port)) {
            my $a = ui_ask("$ui_label{$r} functional probe TCP port (0 to skip)",
                defined($def)?$def:'0');
            last unless defined($a) && $a ne '0';
            if ($a =~ /\A[1-9]\d{0,4}\z/ && grep {$_ == $a} @ports) {
                $port = 0+$a;
                last
            }
            print 'Choose an observed port: ', join(', ', @ports), " or 0.\n";
        }
        unless ($port) {
            print "  $ui_label{$r}: probe skipped; activation would be blocked.\n";
            next
        }
        my $p = $r eq 'spider'?{type => 'prompt', port => $port,
            expect => 'login: '}:{type => 'title',
            port => $port, path => '/', status => 200,
            expect => $r eq 'web'?'DXSpider Web':'DXSpider Web Supervision'};
        my $saved = $manual_launch_dir;
        my ($ok) = ui_step("Verifying $ui_label{$r} functional endpoint (read only)", sub{
            if ($o->{manual}) {
                $manual_launch_dir = "$root/perl";
                manual_contract($o->{process}, $p)
            } else {
                probe_unit($r, $p, $o->{unit_info})
            }
            return 1
        });
        $manual_launch_dir = $saved;
        $probes{$r} = $p if $ok;
    }
    print {$ui_log} "Functional observations: ", $json->encode(\%probes), "\n" if $ui_log;
    return \%probes;
}

sub ui_gib {
    sprintf('%.2f GiB', $_[0]/1073741824)
}

sub ui_capacity {
    my ($download) = @_;
    my ($need, $in, $detail) = capacity($download, 0, 1);
    my ($free, $free_n) = available_capacity();
    return {%$detail, need => $need, in => $in, free => $free, free_n => $free_n,
        fits => ($free >= $need && $free_n >= $in)?1:0};
}

sub ui_capacity_table {
    my ($c) = @_;
    print {$ui_log} "CAPACITY ", $json->encode($c), "\n" if $ui_log;
    for my $pair(['Available', $c->{free}], ['Required (peak)', $c->{need}],
        ['Additional backup (included)', $c->{backup}], ['Remaining at peak',
        $c->{free}-$c->{need}]) {
        printf "  %-30s %s\n", $pair->[0].':', ui_gib($pair->[1])
    }
    print $c->{fits}?"  Capacity: OK (space and inodes)\n":"  Capacity: BLOCK - insufficient space or inodes.\n";
}

sub ui_tracked_changes {
    my ($dirty) = @_;
    return ('NO_GIT') if $dirty eq 'NO_GIT';
    return grep {$_ !~ /\A(?:\?\?|!!) /} split /\0/, $dirty;
}

sub ui_compare_history {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {ui_compare_history(@args)});
    }
    my ($candidate, $old, $new) = @_;
    return 'Same revision' if $old eq $new;
    return 'Revision relationship not verified' unless $old =~ /\A[0-9a-f]{40,64}\z/
        && $new =~ /\A[0-9a-f]{40,64}\z/;
    for my $repo($candidate, $root) {
        my ($old_ok) = capture_status(git($repo, 'cat-file', '-e', "$old^{commit}"));
        next unless $old_ok;
        my ($new_ok) = capture_status(git($repo, 'cat-file', '-e', "$new^{commit}"));
        next unless $new_ok;
        my ($forward) = capture_status(git($repo, 'merge-base', '--is-ancestor', $old, $new));
        return 'Forward update (installed commit is an ancestor)' if $forward;
        my ($backward) = capture_status(git($repo, 'merge-base', '--is-ancestor', $new, $old));
        return 'Older revision (target is an ancestor of installed commit)' if $backward;
        my ($common) = capture_status(git($repo, 'merge-base', $old, $new));
        return 'Diverged revisions (neither is an ancestor)' if $common;
    }
    return 'Different revision; direction not verified from available Git history';
}

# ==========================================================================
# 18. Operator transaction and recovery workflows
# ==========================================================================

sub ui_journal {
    my $w = transaction_layout($root, $owner)->{work};
    my $p = "$w/journal.json";
    return ($w, undef) unless exists_path($p);
    protected_ancestors($w) unless $fixture;
    fail('unsafe journal location') if -l $w || -l $p || !-f $p;
    my @s = stat($p);
    fail('untrusted journal') unless @s && $s[4] == $> && !($s[2]&0022) && $s[7]<1048576;
    my $v = $json->decode(read_file($p));
    fail('journal does not match installation') unless ref($v) eq 'HASH'
        && ($v->{root}//'') eq $root;
    return($w, $v);
}

# ============================================================================
# Restore points: use only completed, verified manager transactions.
# No repository download and no merge with the current user's data.
# ============================================================================
# An older backup has no original digest: the import establishes a digest now.

sub legacy_backup_point {
    my ($dir) = @_;
    path_check($dir);
    fail('backup overlaps active installation') if under($dir, $root) || under($root, $dir);
    fail('backup path must be canonical') unless (realpath($dir)//'') eq $dir;
    my $p = dirname($dir);
    while (1) {
        my @s = lstat($p);
        fail('untrusted legacy backup ancestor') unless @s && S_ISDIR($s[2]) && $s[4] == $>
            && !($s[2]&0022);
        last if $p eq '/';
        $p = dirname($p);
    }
    my @d = lstat($dir);
    fail('unsafe legacy backup directory') unless @d && S_ISDIR($d[2]) && ($d[4] == $>
        || $d[4] == $owner) && !($d[2]&0022);
    sysopen my $fh, "$dir/config.backup",
        O_RDONLY|O_NOFOLLOW or fail('missing legacy backup metadata');
    my @st = stat($fh);
    fail('unsafe legacy backup metadata') unless @st && S_ISREG($st[2]) && $st[3] == 1
        && $st[4] == $>
        && !($st[2]&0022) && $st[7]>0 && $st[7] <= 8192;
    my $raw = '';
    my $n = read($fh, $raw, 8193);
    close $fh;
    fail('invalid legacy backup metadata size') unless defined($n) && $n == $st[7];
    my %fields;
    for my $line (split /\n/, $raw) {
        my ($k, $v) = $line =~ /\A(owner|group|old_type|old_dxs_path|old_service_path)=([^\x00-\x1f\x7f]+)\z/;
        fail('invalid or duplicate legacy backup field') unless defined($k) && !exists($fields{$k});
        $fields{$k} = $v;
    }
    fail('incomplete legacy backup metadata') unless keys(%fields) == 5;
    fail('legacy backup belongs to a different installation')
        unless (realpath($fields{old_dxs_path})//'') eq $root;
    fail('invalid legacy startup method') unless $fields{old_type} =~ /\A(?:service|pid)\z/;
    fail('legacy service path is not the reference Bash path')
        unless $fields{old_service_path} eq '/etc/systemd/system/dxspider.service';
    my @pw = getpwnam($fields{owner});
    my @gr = getgrnam($fields{group});
    fail('legacy backup account does not match current installation') unless @pw && @gr
        && $pw[2] == $owner && $gr[2] == $group;
    my $path = "$dir/spider";
    fail('legacy backup tree is missing or unsafe') unless -d $path && !-l $path
        && (realpath($path)//'') eq $path;
    my $point = {workspace => $dir, path => $path, kind => 'legacy', updated => $st[9],
        legacy_meta_sha => sha256_hex($raw)};
    # Check structure before hashing the complete tree. Do not exclude any logs
    # from a historical Bash backup, which did not use the manager's exclusions.
    verify_restore_point($point);
    require_no_unknown_writers({}, $path);
    $point->{sha} = manifest($path, '.');
    return $point;
}

sub retained_points {
    my $layout = transaction_layout($root, $owner);
    my $parent = $layout->{anchor};
    my $stem = basename($layout->{work});
    opendir my $dh, $parent or fail("cannot list restore points: $!");
    my @names = grep { $_ eq $stem || /\A\Q$stem\E-archive-\d+-[0-9a-f]{12}\z/ } readdir $dh;
    closedir $dh;
    my @points;
    for my $name (sort @names) {
        my $dir = File::Spec->catdir($parent, $name);
        my @st = lstat($dir);
        next unless @st && S_ISDIR($st[2]) && $st[4] == $> && !($st[2]&0066);
        my @js = lstat("$dir/journal.json");
        next unless @js && S_ISREG($js[2]) && $js[4] == $> && !($js[2]&0077) && $js[7]<1048576;
        my $v = eval { $json->decode(read_file("$dir/journal.json")) };
        next unless ref($v) eq 'HASH' && ($v->{version}//0) == 1 && ($v->{root}//'') eq $root
            && ($v->{fixture}//-1) == ($fixture?1:0);
        next unless ($v->{state}//'') =~  /\A(?:COMMITTED|ROLLED_BACK)\z/;
        for my $kind (qw(old backup)) {
            next if $kind eq 'old' && $v->{state} ne 'COMMITTED';
            next unless ($v->{home_layout}//0) == ($layout->{home}?1:0);
            my $tw = $layout->{home}?"$dir/trees":$dir;
            my $path = $kind eq 'old'?"$tw/old":"$tw/backup/spider";
            my $sha = $kind eq 'old'?$v->{old_sha}:$v->{backup_sha};
            next unless defined($sha) && $sha =~  /\A[0-9a-f]{64}\z/ && -d $path && !-l $path
                && (realpath($path)//'') eq $path;
            next if $kind eq 'old' && !same(ident($path), $v->{old_id});
            push @points, {workspace => $dir, path => $path, kind => $kind, sha => $sha,
                updated => $v->{updated}//0};
        }
    }
    return sort { $b->{updated}<=>$a->{updated} || $a->{path} cmp $b->{path} } @points;
}

sub verify_restore_point {
    my ($point) = @_;
    if ($home_fs && !$fs_child) {
        require_no_unknown_writers({}, $point->{path}) if $point->{kind} eq 'legacy';
        return owner_file_call(sub {verify_restore_point($point)});
    }
    my $path = $point->{path};
    no_mounts($path);
    fail('restore point is not a real tree') unless -d $path && !-l $path
        && (realpath($path)//'') eq $path;
    for my $part (@persistent) {
        fail("restore point missing/unsafe $part") unless -d "$path/$part" && !-l "$path/$part";
    }
    fail('restore point has no safe DXVars.pm') unless -f "$path/local/DXVars.pm"
        && !-l "$path/local/DXVars.pm";
    fail('restore point has no real cluster.pl') unless -f "$path/perl/cluster.pl"
        && !-l "$path/perl"
        && !-l "$path/perl/cluster.pl";
    my @s = stat("$path/perl/cluster.pl");
    fail('restore point belongs to a different account') unless $s[4] == $owner && $s[5] == $group;
    if ($point->{kind} eq 'backup') {
        for my $d (@backup_empty) {
            next unless exists_path("$path/$d");
            fail('unsafe excluded backup directory') unless -d "$path/$d" && !-l "$path/$d";
            opendir my $dh, "$path/$d" or fail('cannot read excluded backup directory');
            my @n = grep {$_ ne '.' && $_ ne '..'} readdir $dh;
            closedir $dh;
            fail('unexpected contents in excluded backup directory') if @n;
        }
        fail('backup manifest mismatch') unless manifest($path, ':backup', '.') eq $point->{sha};
    } elsif ($point->{kind} eq 'legacy') {
        require_no_unknown_writers({}, $path) unless $fs_child;
        fail('legacy backup changed since import verification') if defined($point->{sha})
            && manifest($path, '.') ne $point->{sha};
    } else {
        fail('retained original manifest mismatch') unless manifest($path, '.') eq $point->{sha};
    }
    return manifest($path, '.');
}

sub restore_candidate_check {
    if ($home_fs && !$fs_child) {
        my @args = @_;
        return owner_file_call(sub {restore_candidate_check(@args)});
    }
    my $path = "$work/candidate";
    fail('restore candidate identity changed') unless same(ident($path), $j->{new_id});
    fail('restore candidate manifest changed') unless manifest($path, '.') eq $j->{restore_sha};
    fail('restore revision changed') unless git_value($path, 'rev-parse', 'HEAD') eq $j->{head}
        && git_value($path, 'symbolic-ref', '--short', 'HEAD') eq $j->{branch};
    fail('restore version metadata changed')
        unless $json->encode(version_identity($path)) eq $json->encode($j->{git_version_metadata});
}

sub restore_prepare {
    my ($point) = @_;
    # Caller holds the stable installation lock. Re-discover and revalidate;
    # do not trust a path from an interactive selection or CLI argument alone.
    if ($point->{kind} eq 'legacy') {
        my $checked = legacy_backup_point($point->{workspace});
        fail('legacy backup changed since selection') unless $checked->{sha} eq $point->{sha}
            && $checked->{legacy_meta_sha} eq $point->{legacy_meta_sha};
        $point = $checked;
    } else {
        my @match = grep {$_->{path} eq $point->{path}
            && $_->{sha} eq $point->{sha}} retained_points();
        fail('restore point disappeared or changed') unless @match == 1;
        $point = $match[0];
    }
    tools_check();
    no_mounts($root);
    owner_tree_preflight($root);
    owner_tree_preflight($point->{path});
    my $sha = verify_restore_point($point);
    my $size = inventory_sizes($point->{path}, 1, 1, '.');
    my ($mb, $mn) = capacity_margin($size->{bytes}+$size->{sqlite_bytes},
        $size->{inodes}+$size->{sqlite_inodes});
    capacity_check($size->{bytes}+$size->{sqlite_bytes}+$mb,
        $size->{inodes}+$size->{sqlite_inodes}+$mn,
        1);
    my $archived = rollover_workspace();
    if (defined($archived) && $point->{workspace} eq $work) {
        $point->{path} = $archived.substr($point->{path}, length($work));
        $point->{workspace} = $archived;
    }
    fail('restore source changed during archival') unless verify_restore_point($point) eq $sha;
    configure_tmp();
    my $target = ui_revision($point->{path});
    fail('restore branch not supported') unless $target->{branch} =~ /\A(?:mojo|test)\z/;
    fail('restore HEAD unavailable') unless $target->{head} =~ /\A[0-9a-f]{40,64}\z/;
    $branch = $target->{branch};
    $backup = 0; # the complete current tree is retained by rename
    $j = {version => 1, operation => 'restore', root => $root, fixture => $fixture?1:0,
        systemd_fixture => $systemd_fixture?1:0, branch => $branch,
        head => $target->{head}, old_id => ident($root), backup => 0, reserve => $reserve,
            dirty_sha => local_fingerprint($root, local_changes($root)),
        owner => $owner, group => $group, restore_source => $point->{path}, restore_sha => $sha,
            git_version_metadata => version_identity($point->{path})};
    $j->{home_layout} = 1 if $home_fs;
    checkpoint('PLANNED');
    my $tw = tree_work();
    owner_file_call(sub {run('cp', '-a', '--preserve=all', '--', $point->{path}, "$tw/candidate");
        return 1;});
    $j->{new_id} = ident("$tw/candidate");
    restore_candidate_check();
    fail('restore source changed during copy') unless verify_restore_point($point) eq $sha;
    sqlite_check("$tw/candidate");
    restore_candidate_check();
    sync_tree("$tw/candidate");
    checkpoint('STAGED');
    print "RESTORE STAGED $j->{head}; original restore point retained\n";
}

sub ui_restore {
    my ($w, $previous) = ui_journal();
    if ($previous && ($previous->{state}//'') !~ /\A(?:PLANNED|STAGED|COMMITTED|ROLLED_BACK)\z/) {
        ui_section('INTERRUPTED UPDATE OR RESTORE');
        print '  Transaction: ', ui_safe($previous->{state}), "\n  Workspace: ", ui_safe($w), "\n";
        if (!LIVE_ENABLED) {
            print "  Production recovery is unavailable in preview mode. No changes made.\n";
            return 1;
        }
        return 0 unless ui_yes('Recover the previous installation and service state?', 0);
        my ($ok) = ui_step('Recovering interrupted transaction', sub {
            acquire(0);
            load_journal();
            fail('transaction changed since selection')
                unless ($j->{sequence}//0) == ($previous->{sequence}//0) && same($j->{old_id},
                $previous->{old_id}) && same($j->{new_id}, $previous->{new_id});
            recover_tx();
            fail('rollback not verified') unless $j->{state} eq 'ROLLED_BACK';
        });
        close $lock if $lock;
        undef $lock;
        return $ok?0:1;
    }
    ui_section('AVAILABLE RESTORE POINTS');
    my @points = retained_points();
    my $legacy = '/home/spider.backup';
    if (exists_path("$legacy/config.backup")) {
        my $p = eval { legacy_backup_point($legacy) };
        if ($p) { push @points, $p; }
        else { print {$ui_log} "Legacy backup not offered: $@" if $ui_log; }
    }
    print "  No verified previous installation or backup found.\n" unless @points;
    for my $i (0..$#points) {
        my $p = $points[$i];
        my ($ok, $v) = ui_step('Reading restore point version', sub { ui_revision($p->{path}) });
        $v = {} unless $ok;
        $p->{display} = $v;
        printf "  [%d] %s  %s  %s\n", $i+1, POSIX::strftime('%Y-%m-%d %H:%M',
            localtime($p->{updated})),
            $p->{kind} eq 'old'?'Previous installation':$p->{kind} eq 'legacy'?'Bash backup (import checked)':'Additional backup', ui_safe($v->{describe}//'unavailable');
        print "      Branch: ", ui_safe($v->{branch}//'unknown'), "\n";
    }
    print "\n  [B] Select a Bash backup directory\n  [Q] Cancel\n\n";
    my $choice = ui_ask('Select restore point (Q to cancel)', undef);
    return 0 if !defined($choice) || $choice =~ /\Aq\z/i;
    my $p;
    if ($choice =~ /\Ab\z/i) {
        my $dir = ui_ask('Backup directory', '/home/spider.backup');
        return 0 unless defined $dir;
        my ($ok, $point) = ui_step('Checking Bash backup', sub {legacy_backup_point($dir)});
        return 1 unless $ok;
        $p = $point;
        $p->{display} = ui_revision($p->{path});
    } else {
        fail('invalid restore point') unless $choice =~ /\A[1-9][0-9]*\z/ && $choice <= @points;
        $p = $points[$choice-1];
    }
    ui_section('RESTORE PLAN');
    my ($ok, $size) = ui_step('Checking restore point and space', sub {
        verify_restore_point($p);
        my $s = inventory_sizes($p->{path}, 1, 1, '.');
        my ($mb, $mn) = capacity_margin($s->{bytes}+$s->{sqlite_bytes},
            $s->{inodes}+$s->{sqlite_inodes});
        capacity_check($s->{bytes}+$s->{sqlite_bytes}+$mb, $s->{inodes}+$s->{sqlite_inodes}+$mn, 1);
        return $s;
    });
    return 1 unless $ok;
    print '  Installation: ', ui_safe($root), "\n";
    print '  Current: ', ui_safe(ui_revision($root)->{describe}), "\n";
    print '  Restore: ', ui_safe($p->{display}{describe}//'unavailable'), "\n";
    print '  Restore data: ', ui_gib($size->{bytes}), "\n";
    print '  Restore source: ', ui_safe($p->{path}), "\n";
    print "  Bash backup: integrity baseline established now, not at backup creation.\n  Historical service files will not be installed; current startup policy applies.\n" if $p->{kind} eq 'legacy';
    print "\n  Historical configuration and user data will replace current data.\n  The current tree and selected restore point will be retained.\n";
    if (!LIVE_ENABLED) {
        print "\n  Production restoration is not enabled. Only preparation is available.\n";
        return 0 unless ui_yes('Prepare and verify the restore candidate?', 0);
    }
    my ($prepared) = ui_step('Preparing restore candidate', sub {
        acquire(1);
        restore_prepare($p);
        return 1;
    });
    close $lock if $lock;
    undef $lock;
    return 1 unless $prepared;
    ui_result('[ OK ] Restore candidate verified. Active installation unchanged.');
    if (LIVE_ENABLED) {
        ui_section('RESTORE SERVICE PLAN');
        my ($sok, $services) = ui_step('Detecting services', sub {ui_services()});
        return 1 unless $sok;
        ui_service_table($services);
        my $probes = ui_probe_preview($services);
        return ui_execute_staged($services, $probes, {%$j});
    }
    return 0;
}

# Final authorization and transaction execution; do not stop services until
# the operator confirms the verified plan in a live interactive session.

sub ui_execute_staged {
    my ($services, $probes, $expected) = @_;
    fail('production activation disabled') unless LIVE_ENABLED;
    fail('service preflight blocked') if @{$services->{block}};
    for my $r (@start) {
        my $o = $services->{roles}{$r};
        next if $o->{after} =~ /\A(?:Remain stopped|SKIPPED)/;
        fail("functional probe required for $ui_label{$r}") unless $probes->{$r};
    }
    print "\n  The manager will stop and restart the appropriate services.\n  The current installation will be retained.\n";
    return 0 unless ui_yes('Perform the operation now? Services will be interrupted', 0);
    ui_section('EXECUTING TRANSACTION');
    my ($ok, $status) = ui_step('Running verified transaction', sub {
        acquire(0);
        load_journal();
        fail('prepared transaction changed') unless $j->{state} eq 'STAGED' && same($j->{new_id},
            $expected->{new_id}) && same($j->{old_id}, $expected->{old_id})
            && $j->{head} eq $expected->{head};
        my $now = ui_services();
        fail('service inventory changed; repeat the plan') if @{$now->{block}};
        for my $r (@start) {
            my ($a, $b) = ($services->{roles}{$r}, $now->{roles}{$r});
            fail("service status changed: $r") unless $a->{state} eq $b->{state}
                && ($a->{unit}//'') eq ($b->{unit}//'') && $a->{after} eq $b->{after}
                && $json->encode($a->{ports}) eq $json->encode($b->{ports});
            if ($a->{manual}) {
                fail('manual process identity changed') unless $b->{manual}
                    && manual_probe_identity($a->{process}) eq manual_probe_identity($b->{process})
                    && $json->encode($a->{manual_unit_guard}) eq $json->encode($b->{manual_unit_guard});
            } elsif ($a->{unit_info}) {
                fail('unit identity changed') unless $b->{unit_info}
                    && unit_identity($a->{unit_info}) eq unit_identity($b->{unit_info})
                    && same($a->{unit_info}{unit_sha}, $b->{unit_info}{unit_sha});
            }
        }
        $manual_launch_dir = $services->{roles}{spider}{manual}?"$root/perl":'';
        ($spider_port, $web_port,
            $admin_port) = map { $probes->{$_}{port}//0 } qw(spider web admin);
        $probe_config = '';
        local $approved_services = $services;
        my $status = execute_transaction();
        fail('transaction failed; inspect journal and recovery result') if $status;
        return 0;
    });
    close $lock if $lock;
    undef $lock;
    ui_section('OPERATION RESULT');
    if ($ok && !$status && $j->{state} eq 'COMMITTED') {
        ui_result('[ OK ] Operation completed successfully.');
        my $v = ui_revision($root);
        print '  Installation: ', ui_safe($root), "\n  Branch: ", ui_safe($v->{branch}),
            "\n  Version/build: ", ui_safe($v->{describe}), "\n";
        my $tw = tree_work();
        print "  Previous installation: $tw/old\n";
        print "  Additional backup: $tw/backup/spider\n" if $j->{backup};
        return 0;
    }
    ui_result('[FAIL] Operation did not complete.');
    print '  Transaction state: ', ui_safe($j->{state}//'unknown'), "\n  Retained workspace: ",
        ui_safe($work), "\n" if $j;
    return 1;
}

sub ui_update_plan {
    my ($v) = @_;
    my ($w, $existing) = ui_journal();
    if ($existing && (($existing->{state}//'') !~ /\A(?:PLANNED|STAGED|COMMITTED|ROLLED_BACK)\z/ ||
        ($existing->{reconciliation}{status}//'') eq 'REVIEW_REQUIRED')) {
        ui_result('[WARNING] Previous transaction requires recovery or data review.');
        print "  No new update can start until the previous transaction is safe.\n";
        return 1;
    }
    ui_section('1. TARGET BRANCH', 0);
    print "Select the branch to install:\n  [1] mojo\n  [2] test\n\n";
    while (1) {
        my $b = ui_ask('Target branch (mojo or test)',
            $v->{branch} =~ /^(?:mojo|test)$/?$v->{branch}:'mojo');
        return unless defined $b;
        $b = 'mojo' if $b eq '1';
        $b = 'test' if $b eq '2';
        last if ($branch = $b) =~ /\A(?:mojo|test)\z/;
        print "Choose 1 (mojo) or 2 (test).\n"
    }
    my ($ok, $heads) = ui_step('Checking remote revisions', sub{
        my @h = map {remote_head($_, $branch)} @remote;
        fail('no remote revision available') unless defined $h[0] || defined $h[1];
        print "Remote revisions: ", $json->encode(\@h), "\n";
        return \@h
    });
    return 1 unless $ok;
    my ($a, $b) = @$heads;
    my ($rok, $status) = ui_step('Comparing revisions', sub{
        my $s = revision_status($root, $a, $b);
        print "Revision result: $s\n";
        return $s
    });
    return 1 unless $rok;
    if ($status eq 'UP_TO_DATE') {
        ui_section('ALREADY UP TO DATE');
        print "  No services stopped. Installation unchanged.\n";
        return 0
    }
    if (defined($a) && defined($b) && $a ne $b) {
        print "WARNING: mirror differs from primary; it cannot be used as fallback for this revision.\n"
    }
    print "\nVERSION COMPARISON (before download)\n  Target branch: $branch\n  Target revision: ",
        substr(($a//$b), 0, 12), "\n  Exact target build will be shown after download.\n";
    ui_section('2. BACKUP AND SPACE');
    print '  Installed: ', ui_safe($v->{branch}), ' / ', ui_safe($v->{describe}),
        "\n  Target: $branch / ", substr(($a//$b), 0, 12), "\n\n";
    $backup = ui_yes('Create an additional backup? (Recommended)', 1);
    return unless defined $backup;
    my ($t) = ui_step('Checking installation', sub{
        tools_check();
        no_mounts($root);
        owner_tree_preflight($root);
        for my $d(@persistent) {
            fail("missing/unsafe $d") unless -d "$root/$d" && ! -l "$root/$d"
        }
        return 1
    });
    my ($cok, $c) = ui_step('Calculating disk space', sub{
        ui_capacity(1)
    });
    ui_capacity_table($c) if $cok;
    ui_section('3. SERVICES');
    my ($sok, $s) = ui_step('Detecting services', sub{
        ui_services()
    });
    my $probes = {};
    if ($sok) {
        ui_service_table($s);
        print "\n";
        $probes = ui_probe_preview($s);
    }
    ui_section('4. UPDATE PREPARATION PLAN');
    print '  Installation: ', ui_safe($root), "\n  Current: ", ui_safe($v->{branch}), ' / ',
        ui_safe($v->{describe}), "\n  Target: $branch / ", substr(($a//$b), 0, 12), "\n\n";
    ui_capacity_table($c) if $cok;
    print "\n";
    ui_service_table($s) if $sok;
    my ($dok, $dirty) = ui_step('Checking local files', sub{
        my $d = local_changes($root);
        print "LOCAL CHANGES ", $json->encode([split /\0/, $d]), "\n";
        return $d
    });
    return 1 unless $dok;
    my @tracked = ui_tracked_changes($dirty);
    $allow_dirty = 1; # ordinary ignored/untracked files stay in the original tree
    if (@tracked) {
        print "\n  WARNING: ",
            ($dirty eq 'NO_GIT'?'Installed tree has no Git metadata; local program changes cannot be checked.':'Locally modified versioned program files will be replaced.'), "\n  The original tree is retained. See technical log for details.\n";
        $allow_dirty = ui_yes('Continue with repository program files?', 0);
        unless ($allow_dirty) {
            print "Cancelled. No services stopped.\n";
            return
        }
    }
    print "\n  Configuration and user data will be preserved.\n  Program files and data/ will be replaced from the repository.\n  Original installation retained for rollback.\n  Additional backup: ", ($backup?'YES':'NO'), "\n\n  The updater will automatically:\n    1. Stop the appropriate running services.\n    2. Preserve data, check databases and create backup if selected.\n    3. Activate the new installation.\n    4. Restart the appropriate services and verify.\n    5. Restore the original if verification fails.\n\n  No manual service stop or restart is required for running services.\n";
    print "  PREVIEW ONLY: no services will be stopped.\n" unless LIVE_ENABLED;
    print "  Service blockers above must be resolved before activation.\n" if $sok
        && @{$s->{block}};
    unless ($t && $cok && $c->{fits} && $sok) {
        print "Preparation blocked by failed checks. No services stopped.\n";
        return 1
    }
    if (!ui_yes('Download and verify candidate now? (No downtime)', 0)) {
        print "Cancelled. No services stopped, no candidate downloaded.\n";
        return
    }
    ui_section('5. DOWNLOADING CANDIDATE');
    my ($staged) = ui_step('Preparing verified Git candidate', sub{
        local @ENV{qw(TMPDIR TEMP TMP)};
        fail('root required for staging') unless $> == 0;
        my @now = ui_tracked_changes(local_changes($root));
        fail('versioned file status changed; review plan again') unless join("\0",
            @now) eq join("\0",
            @tracked);
        acquire(1);
        rollover_workspace();
        prepare();
        return 1
    });
    close $lock if $lock;
    undef $lock;
    if ($staged && $j && $j->{state} eq 'STAGED') {
        ui_section('6. CANDIDATE READY - VERIFIED UPDATE COMPARISON');
        printf "  %-16s %-25s %s\n", '', 'INSTALLED', 'TARGET';
        printf "  %-16s %-25s %s\n", 'Branch', ui_safe($v->{branch}), $j->{branch};
        printf "  %-16s %-25s %s\n", 'Version/build', ui_safe($v->{describe}),
            ui_safe($j->{git_version_metadata}{describe}//'unavailable');
        printf "  %-16s %-25s %s\n", 'Revision', substr(ui_safe($v->{head}), 0, 12),
            substr($j->{head},
            0, 12);
        my ($relok, $rel) = ui_step('Checking revision history', sub{
            ui_compare_history(tree_work()."/candidate", $v->{head}, $j->{head})
        });
        $rel = 'Same revision - branch change only'
        if $relok && $rel eq 'Same revision' && $v->{branch} ne $j->{branch};
        print "  ", ($relok?$rel:'Revision relationship not verified'), "\n";
        print "\n  Source: ", ui_safe($j->{remote}), "\n";
        print {$ui_log} "Candidate workspace: $work\n";
        my ($ck, $cap) = ui_step('Rechecking space after download', sub{
            ui_capacity(0)
        });
        ui_capacity_table($cap) if $ck;
        print "\n  Backup: ", ($backup?'YES':'NO'), "\n";
        ui_service_table($s);
        if (LIVE_ENABLED) {
            return ui_execute_staged($s, $probes, {%$j}) if $ck && $cap->{fits};
            ui_result('[FAIL] Capacity check did not pass. No services stopped.');
            return 1;
        }
        ui_result('[SKIPPED] Stop services, migrate, activate, restart and verify: production disabled.');
        print "\n", ('-' x 62), "\n PREPARATION COMPLETE\n", ('-' x 62), "\n\n";
        print "  Candidate verified and retained.\n  Installed version unchanged.\n  No services stopped.\n";
        print "  Technical log: $ui_logpath\n" if $ui_logpath;
        return ($ck && $cap->{fits}) ? 0 : 1;
    } elsif ($staged) {
        print "No candidate needed. Installation unchanged.\n";
        return 0
    } else {
        print "Preparation failed; inspect the technical log. No services stopped.\n";
        return 1
    }
}

# ==========================================================================
# 19. Clean installation planning and staging
# ==========================================================================

# ============================================================================
# Clean-install planning and verified staging.
# Host changes are permitted only after explicit live interactive approval.
# ============================================================================

sub install_distro_map {
    # Exact distro_actions(2).conf received on 2026-11-22.
    my $table=<<'DISTROS';
CentOS Linux 8,install_epel_8 ; install_package_CentOS_8
Rocky Linux 8,install_epel_8 ; install_package_CentOS_8
Rocky Linux 9,install_epel_9 ; install_package_Rocky_9
AlmaLinux 9,install_epel_9 ; install_package_Rocky_9
Raspbian GNU/Linux 9,install_package_debian
Raspbian GNU/Linux 10,install_package_debian
Raspbian GNU/Linux 11,install_package_debian
Raspbian GNU/Linux 12,install_package_debian
Raspbian GNU/Linux 13,install_package_debian
Debian GNU/Linux 9,install_package_debian
Debian GNU/Linux 10,install_package_debian
Debian GNU/Linux 11,install_package_debian
Debian GNU/Linux 12,install_package_debian
Debian GNU/Linux 13,install_package_debian
Ubuntu 22,install_package_debian
Ubuntu 24,install_package_debian
Ubuntu 25,install_package_debian
Ubuntu 26,install_package_debian
Fedora Linux 39,install_package_Rocky_9
Fedora Linux 40,install_package_Rocky_9
Fedora Linux 41,install_package_Rocky_9
Linux Mint 21,install_package_debian
zorin,install_package_debian
DISTROS
    return {map { split /,/, $_, 2 } split /\n/, $table};
}

sub install_distro {
    my ($text) = @_;
    my ($id) = $text =~ /^ID="?([a-z0-9_-]+)"?$/m;
    my ($major) = $text =~ /^VERSION_ID="?(\d+)(?:\.[^"\n]*)?"?$/m;
    my %names = (ubuntu => 'Ubuntu', linuxmint => 'Linux Mint', debian => 'Debian GNU/Linux',
        raspbian => 'Raspbian GNU/Linux', fedora => 'Fedora Linux', centos => 'CentOS Linux',
        rocky => 'Rocky Linux', almalinux => 'AlmaLinux');
    my $key = ($id//'') eq 'zorin'?'zorin':defined($major)
        && exists($names{$id//''})?"$names{$id} $major":'';
    my $map = install_distro_map();
    fail('distribution is not listed in the supplied installer configuration')
        unless exists $map->{$key};
    return ($key, [split /\s*;\s*/, $map->{$key}]);
}

sub install_dependency_commands {
    my ($actions) = @_;
    my @rpm=qw(
        git curl gzip coreutils procps-ng rsync tar util-linux perl gcc make perl-TimeDate
        perl-Time-HiRes perl-Curses perl-Net-Telnet perl-Data-Dumper perl-DB_File
        perl-ExtUtils-MakeMaker perl-Digest-MD5 perl-Digest-SHA perl-IO-Compress
        perl-Net-CIDR-Lite perl-App-cpanminus perl-JSON perl-JSON-XS perl-Mojolicious
        perl-Data-Structure-Util perl-Math-Round perl-EV perl-DBI perl-DBD-SQLite perl-DBD-MySQL
        perl-DBD-MariaDB
    );
    my @deb=qw(
        perl git rsync curl iproute2 gzip procps tar coreutils util-linux build-essential
        cpanminus libssl-dev zlib1g-dev libtimedate-perl libnet-telnet-perl libcurses-perl
        libdigest-sha-perl libdata-dumper-simple-perl libjson-perl libmojolicious-perl
        libdata-structure-util-perl libmath-round-perl libev-perl libjson-xs-perl
        libnet-cidr-lite-perl libdbi-perl libdbd-sqlite3-perl libhtml-parser-perl
        libio-socket-inet6-perl libarchive-zip-perl libmailtools-perl libwww-perl libio-pty-perl
        libauthen-sasl-perl libnet-smtp-ssl-perl libemail-sender-perl
    );
    my @cmd;
    for my $a (@$actions) {
        if ($a eq 'install_epel_8' || $a eq 'install_epel_9') {
            push @cmd, ['dnf', '-y', 'makecache', '--refresh'], ['dnf', '-y', 'install',
                'epel-release'];
        } elsif ($a eq 'install_package_CentOS_8' || $a eq 'install_package_Rocky_9') {
            push @cmd, ['dnf', '-y', 'makecache', '--refresh'], ['dnf', '-y', 'install', @rpm];
        } elsif ($a eq 'install_package_debian') {
            push @cmd, ['apt-get', 'update', '-y'], ['apt-get', 'install', '-y', @deb];
        } else { fail('unrecognized distribution action'); }
    }
    return \@cmd;
}

sub install_account_name {
    my ($s) = @_;
    # Restrict the planned Unix identifiers to portable simple names.
    fail('invalid account/group name') unless defined($s) && $s =~ /\A[a-z_][a-z0-9_-]{0,30}\z/;
    return $s;
}

sub install_path_anchor {
    my ($dest) = @_;
    path_check($dest);
    fail('reserved installation location') if $dest eq '/' || $dest eq '/home' || $dest eq '/root'
        || under($dest, '/tmp') || under($dest, '/var/tmp') || under($dest, '/proc')
        || under($dest, '/sys') || under($dest, '/dev') || under($dest, '/etc')
        || under($dest, '/var/log');
    fail('installation destination already exists; nothing will be overwritten')
        if exists_path($dest);
    my $parent = dirname($dest);
    while (!exists_path($parent)) {
        $parent = dirname($parent);
    }
    fail('installation parent is a symlink or noncanonical') unless -d $parent
        && (realpath($parent)//'') eq $parent;
    my $dev = (stat($parent))[0];
    my $p = $parent;
    while (1) {
        my @s = lstat($p);
        fail('unsafe installation ancestor') unless @s && S_ISDIR($s[2]);
        if ($s[4] == 0 && !($s[2]&0022) && $s[0] == $dev) {
            my $q = $p;
            my $trusted = 1;
            while (1) {
                my @a = lstat($q);
                if (!@a || !S_ISDIR($a[2]) || $a[4] != 0 || ($a[2]&0022)) {
                    $trusted = 0;
                    last;
                }
                last if $q eq '/';
                $q = dirname($q);
            }
            return $p if $trusted;
        }
        last if $p eq '/';
        $p = dirname($p);
    }
    fail('no trusted staging directory on target filesystem');
}

sub install_callsign {
    my ($s) = @_;
    $s = uc($s//'');
    # Same pattern as DXUtil::is_callsign in the supplied revision.
    fail('invalid callsign') if $s =~ /^Q\w+$/i || $s =~ /^R[A\d]+N+D[O\d]+M+$/i
        || $s !~ m!\A(?:\d?[A-Z]{1,2}\d{0,2}/)?(?:\d?[A-Z]{1,2}\d{1,5})[A-Z]{1,8}(?:-\d{1,2})?(?:/[0-9A-Z]{1,7})?(?:/(?:AM?|MM?|P))?\z!;
    return $s;
}

sub install_locator_center {
    my ($q) = @_;
    $q = uc($q//'');
    fail('six-character Maidenhead locator required') unless $q =~ /\A[A-R]{2}[0-9]{2}[A-X]{2}\z/;
    my ($p1, $p2, $p3, $p4, $p5, $p6) = unpack 'AAAAAA', $q;
    # DXBearing::qratoll in the exact candidate supplied by the operator.
    my $lon = (ord($p1)-65)*20+$p3*2+(ord($p5)-65+0.5)/12-180;
    my $lat = (ord($p2)-65)*10+$p4+(ord($p6)-65+0.5)/24-90;
    return ($q, $lat, $lon);
}

sub install_perl_literal {
    my ($value) = @_;
    fail('empty or invalid configuration value') unless defined($value) && length($value)
        && $value !~ /[\x00-\x1f\x7f]/;
    $value =~ s/([\\'])/\\$1/g;
    return "'$value'";
}

sub install_configure_candidate {
    my ($tree, $cfg) = @_;
    for my $d (@persistent, 'cmd_import') {
        mkdir("$tree/$d", 0700) or fail("create $d: $!") unless exists_path("$tree/$d");
        fail("unsafe installation directory $d") unless -d "$tree/$d" && !-l "$tree/$d";
    }
    for my $d ('local_data') {
        opendir my $dh, "$tree/$d" or fail('cannot inspect fresh data directory');
        my @n = grep {$_ ne '.' && $_ ne '..' && $_ ne '.gitignore'
            && $_ ne '.cvsignore'} readdir $dh;
        closedir $dh;
        fail('fresh clone unexpectedly contains runtime data') if @n;
    }
    my $node = install_callsign($cfg->{node});
    my $sysop = install_callsign($cfg->{sysop});
    fail('node and SYSOP callsigns must differ') if $node eq $sysop;
    my ($q, $lat, $lon) = install_locator_center($cfg->{locator});
    my %v = (mycall => install_perl_literal($node), myalias => install_perl_literal($sysop),
        myname => install_perl_literal($cfg->{name}),
        myemail => install_perl_literal($cfg->{email}),
        mylocator => install_perl_literal($q), myqth => install_perl_literal($cfg->{qth}),
        mylatitude => sprintf('%.8f', $lat), mylongitude => sprintf('%.8f', $lon));
    my $file = "$tree/perl/DXVars.pm.issue";
    fail('missing DXVars template') unless -f $file && !-l $file;
    my $s = read_file($file);
    for my $k (sort keys %v) {
        my $n = ($s =~ s/^(\s*(?:our\s+)?\$\Q$k\E\s*=\s*)[^\n;]*(;[^\n]*)$/$1$v{$k}$2/mg);
        fail("DXVars template field $k is not unique") unless $n == 1;
    }
    fail('unexpected SQLite DSN template; review required')
        unless $s =~ /^\s*our\s+\$userdsn\s*=\s*"dbi:SQLite:dbname=\$root\/local_data\/dxusers\.db"\s*;/m;
    write_file("$tree/local/DXVars.pm", $s);
    my $port = $cfg->{port};
    fail('invalid listener port') unless defined($port) && $port =~ /\A[0-9]+\z/ && $port >= 1
        && $port <= 65535;
    fail('Telnet port conflicts with DXSpider internal port 27754') if $port == 27754;
    my $lf = "$tree/perl/Listeners.pm";
    fail('missing listener template') unless -f $lf && !-l $lf;
    my $l = read_file($lf);
    my $count = ($l =~ s/^([ \t]*)#[ \t]*(\["0\.0\.0\.0",\s*)7300(\],.*)$/$1$2$port$3/mg);
    fail('IPv4 listener template is not unique') unless $count == 1;
    write_file("$tree/local/Listeners.pm", $l);
    return 1;
}

sub install_prepare_candidate {
    my ($cfg) = @_;
    fail('root required for installation preparation') unless $> == 0;
    tools_check();
    my $anchor = install_path_anchor($cfg->{destination});
    $root = File::Spec->catdir($anchor, '.dxs-install-capacity-check');
    $home_fs = 0; $home_anchor = undef;
    $owner = $>;
    $group = (stat($anchor))[5];
    $fixture = 0;
    # A remote repository size is not known before the clone; use a minimum
    # safety floor, not a claimed exact estimate. Check real size afterwards.
    my ($mb, $mn) = capacity_margin(0, 0);
    capacity_check($mb, $mn, 1);
    $work = File::Spec->catdir($anchor, '.dxs-install-'.time.'-'.substr(random_token(), 0, 12));
    mkdir($work, 0700) or fail('create private install staging directory');
    sync_dir($anchor);
    configure_tmp();
    $branch = $cfg->{branch};
    $j = {operation => 'install-preparation', branch => $branch};
    stage_git(sub { capacity_check($mb, $mn, 1) });
    my $candidate = "$work/candidate";
    install_configure_candidate($candidate, $cfg);
    my $size = inventory_sizes($candidate, 1, 0, '.');
    my $sha = manifest($candidate, '.');
    sync_tree($candidate);
    write_file("$work/install-plan.json", $json->encode({version => 1,
        operation => 'install-preparation', destination => $cfg->{destination},
        user => $cfg->{user},
        group => $cfg->{group}, branch => $branch, head => $j->{head}, remote => $j->{remote},
        version_metadata => $j->{git_version_metadata}, port => $cfg->{port},
        startup => $cfg->{startup}, candidate_sha => $sha, state => 'STAGED',
        bytes => $size->{bytes},
        inodes => $size->{inodes}, created => time})."\n");
    sync_dir($work);
    $root = $cfg->{destination};
    print "INSTALL PREPARATION STAGED $work\n";
    return {path => $work, bytes => $size->{bytes},
        describe => $j->{git_version_metadata}{describe}//'unavailable', head => $j->{head}};
}

# ==========================================================================
# 19b. Clean installation execution primitives
# ==========================================================================
# The physical destination must remain compatible with acquire() afterwards.
# Do not change ownership of a user's home merely to satisfy that restriction.

sub install_managed_parent {
    my ($dest, $home) = @_;
    install_path_anchor($dest);
    fail('home-managed parent requires privilege separation; choose a protected physical directory')
        if defined($home) && under($dest, $home) && !-d $home;
    my $parent = dirname($dest);
    my $p = $parent;
    while (!exists_path($p)) { $p = dirname($p); }
    while (1) {
        my @s = lstat($p);
        fail("installation parent is not root-managed: $p") unless @s && S_ISDIR($s[2])
            && $s[4] == 0
            && !($s[2]&0022);
        last if $p eq '/';
        $p = dirname($p);
    }
    return $parent;
}

sub install_make_managed_parent {
    my ($dest, $home) = @_;
    my $parent = install_managed_parent($dest, $home);
    my @missing;
    my $p = $parent;
    while (!exists_path($p)) {
        unshift @missing, $p;
        $p = dirname($p);
    }
    for my $dir (@missing) {
        mkdir($dir, 0755) or fail("create installation parent $dir: $!");
        chmod(0755, $dir) or fail("mode installation parent $dir");
        sync_dir(dirname($dir));
    }
    return install_managed_parent($dest, $home);
}

# Validate the chosen physical path without modifying an existing HOME.
# A missing home for a new account is allowed only under a protected ancestor;
# the actual account's home and identity are rechecked after useradd.

sub install_parent_plan {
    my ($dest, $home, $uid) = @_;
    my $anchor = install_path_anchor($dest);
    fail('installation cannot replace the account HOME') if defined($home) && $dest eq $home;
    my $p = dirname($dest);
    $p = dirname($p) until exists_path($p);
    my $layout = transaction_layout(File::Spec->catfile($p, '.dxs-layout-probe'), $uid);
    fail('unknown account owns destination ancestry') if $layout->{home} && !defined($uid);
    if (!defined($uid) && defined($home) && under($dest, $home)) {
        fail('new account HOME already exists') if exists_path($home);
    }
    return $layout;
}

sub install_account_parent {
    my ($dest, $account) = @_;
    my $layout = install_parent_plan($dest, $account->{home}, $account->{uid});
    my @missing;
    my $p = dirname($dest);
    while (!exists_path($p)) {
        unshift @missing, $p;
        $p = dirname($p);
    }
    my $make = sub {
        for my $dir (@missing) {
            mkdir($dir, 0750) or fail("create installation parent $dir: $!");
            chmod(0750, $dir) or fail("mode installation parent $dir");
            sync_dir(dirname($dir));
        }
        return 1;
    };
    if ($layout->{home}) {
        my @saved = ($home_fs, $owner, $group, $work);
        ($home_fs, $owner, $group, $work) = (1, $account->{uid}, $account->{gid}, undef);
        my $ok = eval {owner_file_call($make); 1}; my $err = $@;
        ($home_fs, $owner, $group, $work) = @saved;
        die $err unless $ok;
    } else {
        # Preserve the existing protected-parent implementation and traversal.
        install_make_managed_parent($dest, $account->{home});
    }
    return transaction_layout($dest, $account->{uid});
}

sub install_home_data_check {
    my ($w, $plan) = @_;
    fail('home publication plan not bound to account') unless $plan->{home_layout}
        && ($plan->{uid}//0)>0 && ($plan->{gid}//0)>0;
    my @st = lstat("$w/trees");
    fail('unsafe home install data workspace') unless @st && S_ISDIR($st[2])
        && $st[4] == $plan->{uid}
        && $st[5] == $plan->{gid} && !($st[2]&0077) && $st[0] == (stat($w))[0];
    return 1;
}

# Pure plan; executable commands are argument lists, never shell strings.
sub install_account_commands {
    my ($cfg, $pw, $gr, $member) = @_;
    my $u = install_account_name($cfg->{user});
    my $g = install_account_name($cfg->{group});
    fail('root is not a clean-install SYSOP account') if $u eq 'root' || ($pw && $pw->[2] == 0);
    fail('root is not a clean-install group') if $g eq 'root' || ($gr && $gr->[2] == 0);
    my @cmd;
    push @cmd, ['groupadd', $g] unless $gr;
    push @cmd, ['useradd', '-m', '-s', '/bin/bash', '-g', $g, $u] unless $pw;
    push @cmd, ['usermod', '-aG', $g, $u] if $pw && !$member;
    return \@cmd;
}

sub install_create_accounts {
    my ($cfg) = @_;
    my @pw = getpwnam($cfg->{user});
    my @gr = getgrnam($cfg->{group});
    my $member = @pw && @gr && ($pw[3] == $gr[2] || grep {$_ eq $cfg->{user}} split /\s+/,
        $gr[3]//'');
    my $commands = install_account_commands($cfg, @pw?\@pw:undef, @gr?\@gr:undef, $member);
    run(@$_) for @$commands;
    @pw = getpwnam($cfg->{user}); @gr = getgrnam($cfg->{group});
    fail('account creation or group assignment failed') unless @pw && @gr && $pw[2]>0 && $gr[2]>0
        && ($pw[3] == $gr[2] || grep {$_ eq $cfg->{user}} split /\s+/, $gr[3]//'');
    return {uid => $pw[2], gid => $gr[2], home => $pw[7],
        new_account => scalar(grep {$_->[0] eq 'useradd'} @$commands)?1:0};
}

sub install_dependencies {
    my ($actions, $scratch) = @_;
    fail('dependency workspace must be private') unless -d $scratch && !-l $scratch
        && (stat($scratch))[4] == 0 && !((stat($scratch))[2]&0077);
    local $ENV{TMPDIR} = $scratch;
    local $ENV{TEMP} = $scratch;
    local $ENV{TMP} = $scratch;
    local $ENV{PERL_CPANM_HOME} = "$scratch/cpanm";
    local $ENV{DEBIAN_FRONTEND} = 'noninteractive';
    my $commands = install_dependency_commands($actions);
    for my $cmd (@$commands) {
        fail("missing package manager $cmd->[0]") unless find_tool($cmd->[0]);
        ui_event('Installing required system packages');
        run(@$cmd);
    }
    my @missing = missing_runtime_modules([]);
    if (@missing) {
        my $cpanm = find_tool('cpanm') or fail('missing cpanminus after native packages');
        for my $module (@missing) {
            ui_event("Installing missing Perl module $module");
            run($^X, $cpanm, $module);
        }
    }
    @missing = missing_runtime_modules([]);
    fail('DXSpider Perl modules still missing: '.join(',', @missing)) if @missing;
    tools_check();
    return 1;
}

# Preserve tracked executable bits. The reference installer uses group-writable
# data and setgid directories; never chmod through a symlink or an external hardlink.

sub install_assign_tree {
    my ($tree, $uid, $gid) = @_;
    fail('non-root SYSOP and group required') unless $uid>0 && $gid>0;
    no_mounts($tree);
    manifest($tree, '.'); # rejects special files and external hardlinks
    run('chown', '-hR', '--no-dereference', "$uid:$gid", '--', $tree);
    walk($tree, sub {
        my ($path, $st) = @_;
        fail('ownership assignment failed') unless $st->[4] == $uid && $st->[5] == $gid;
        return if S_ISLNK($st->[2]);
        my $mode = S_ISDIR($st->[2])?02775:0664|(($st->[2]&0111)?0111:0);
        chmod($mode, $path) or fail("mode $path: $!");
    }, (stat($tree))[0]);
    sync_tree($tree);
}

sub install_service_text {
    my ($cfg, $physical) = @_;
    my $u = install_account_name($cfg->{user});
    my $g = install_account_name($cfg->{group});
    path_check($physical);
    fail('unsafe systemd path') unless $physical=~m{\A/[A-Za-z0-9_./-]+\z};
    my $perl = realpath($^X) or fail('cannot resolve Perl');
    fail('unsafe Perl path') unless $perl=~m{\A/[A-Za-z0-9_./-]+\z};
    return "[Unit]\nDescription=DXSpider DXCluster service\nAfter=network.target\n\n[Service]\nType=simple\nUser=$u\nGroup=$g\nWorkingDirectory=$physical/perl\nExecStart=$perl -w $physical/perl/cluster.pl\nKillMode=control-group\nStandardOutput=null\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n";
}

sub install_account_prefix {
    my ($uid, $gid) = @_;
    fail('invalid non-root installation credentials') unless $uid>0 && $gid>0;
    my $tool = find_tool('setpriv') or fail('setpriv required for isolated account execution');
    return ($tool, "--reuid=$uid", "--regid=$gid", '--init-groups', '--reset-env', '--');
}

# Install publication is separate from update/restore: never consume an existing
# tree. File activation is journaled before renaming the candidate or creating
# the canonical alias. Retain new files on any ambiguous failure.

sub install_checkpoint {
    my ($plan, $state) = @_;
    $plan->{state} = $state;
    $plan->{updated} = time;
    atomic_write("$work/install-plan.json", $json->encode($plan)."\n");
    print "INSTALL STATE $state\n";
}

sub install_publish_tree {
    my ($cfg, $prepared, $account, $alias) = @_;
    my $dest = $cfg->{destination};
    path_check($alias);
    install_path_anchor($dest);
    fail('installation parent not prepared') unless -d dirname($dest);
    my $layout = transaction_layout($dest, $account->{uid});
    $home_fs = 0;
    my $dir = $prepared->{path};
    fail('untrusted prepared workspace') unless (realpath($dir)//'') eq $dir;
    my @st = lstat($dir);
    fail('unsafe installation workspace') unless @st && S_ISDIR($st[2]) && $st[4] == 0
        && !($st[2]&0077)
        && $st[0] == (stat(dirname($dest)))[0];
    $work = $dir;
    my $plan = $json->decode(read_file("$work/install-plan.json"));
    fail('installation preparation does not match selected settings')
        unless $plan->{state} eq 'STAGED'
        && $plan->{destination} eq $dest && $plan->{user} eq $cfg->{user}
        && $plan->{group} eq $cfg->{group} && $plan->{branch} eq $cfg->{branch}
        && $plan->{port} == $cfg->{port} && $plan->{startup} eq $cfg->{startup};
    my $tree = "$work/candidate";
    fail('candidate contents changed') unless manifest($tree, '.') eq $plan->{candidate_sha};
    fail('canonical alias already in use') if $alias ne $dest && exists_path($alias);
    my $parent = dirname($alias);
    while (1) {
        my @p = lstat($parent);
        fail('unsafe canonical alias ancestor') unless @p && S_ISDIR($p[2]) && $p[4] == 0
            && !($p[2]&0022);
        last if $parent eq '/';
        $parent = dirname($parent);
    }
    # Verify that the selected Unix account can traverse all parents before
    # assigning the candidate; never modify access to existing HOME directories.
    my @prefix = install_account_prefix($account->{uid}, $account->{gid});
    run(@prefix, '/usr/bin/test', '-x', dirname($dest));
    $plan->{candidate_id} = ident($tree);
    $plan->{alias} = $alias;
    $plan->{uid} = $account->{uid};
    $plan->{gid} = $account->{gid};
    $plan->{home_layout} = $layout->{home};
    ($owner, $group) = @$account{qw(uid gid)};
    install_checkpoint($plan, 'ASSIGNING');
    install_assign_tree($tree, $account->{uid}, $account->{gid});
    $plan->{assigned_sha} = manifest($tree, '.');

    if ($layout->{home}) {

        # All root writes to candidate contents have finished. Transfer the
        # private stage to the account before exposing only traversal of work.

        mkdir("$work/trees", 0700) or fail('create home installation data workspace');
        move_tree($tree, "$work/trees/candidate");
        chown($owner, $group,
            "$work/trees") == 1 or fail('assign home installation data workspace');
        sync_dir("$work/trees"); sync_dir($work);
        chmod(0711, $work) or fail('expose protected workspace traversal');
        sync_dir($work);
        $home_fs = 1;
        $tree = tree_work().'/candidate';
        install_home_data_check($work, $plan);
    }

    install_checkpoint($plan, 'ACTIVATING');
    fail('destination or alias occupied since preflight') if exists_path($dest) || ($alias ne $dest
        && exists_path($alias));
    owner_file_call(sub {
        fail('prepared tree identity or contents changed') unless same(ident($tree),
            $plan->{candidate_id}) && manifest($tree, '.') eq $plan->{assigned_sha};
        move_tree($tree, $dest);
        fail('published tree identity mismatch') unless same(ident($dest), $plan->{candidate_id})
            && manifest($dest, '.') eq $plan->{assigned_sha};
        return 1;
    });

    if ($alias ne $dest) {
        symlink($dest, $alias) or fail("create canonical alias: $!");
        sync_dir(dirname($alias));
    }

    fail('canonical alias does not resolve to selected installation')
        unless (realpath($alias)//'') eq $dest;
    $root = $dest;
    ($owner, $group) = @$account{qw(uid gid)};
    install_checkpoint($plan, 'PUBLISHED');
    return $plan;
}

# Recovery of a file-only publication; never remove an active tree, service,
# account, dependency or any unrelated alias. The failed tree is kept intact.

sub install_retain_failed_publication {
    my ($plan) = @_;
    fail('automatic file recovery unsafe after service configuration')
        unless $plan->{state} =~ /\A(?:ACTIVATING|PUBLISHED|DATABASE|DATABASE_READY)\z/;
    my ($dest, $alias) = @$plan{qw(destination alias)};
    my $tree = tree_work().'/candidate';
    my $failed = tree_work().'/failed-install';
    my $active = ident($dest);
    my $staged = ident($tree);
    my $saved = ident($failed);
    fail('ambiguous fresh installation tree identity') unless grep {same($_,
        $plan->{candidate_id})} ($active, $staged, $saved);
    fail('unexpected existing destination') if defined($active) && !same($active,
        $plan->{candidate_id});
    fail('unexpected candidate or failed tree') if (defined($staged)
        && !same($staged, $plan->{candidate_id})) || (defined($saved) && !same($saved,
        $plan->{candidate_id}));
    fail('multiple fresh installation trees') if grep(defined($_), ($active, $staged, $saved)) != 1;
    require_no_unknown_writers({}, $dest, $tree, $failed);
    if ($alias ne $dest && exists_path($alias)) {
        fail('canonical alias has changed; preserve it') unless -l $alias
            && (readlink($alias)//'') eq $dest;
        unlink($alias) or fail('cannot remove newly created alias');
        sync_dir(dirname($alias));
    }
    owner_file_call(sub {
        move_tree($dest, $failed) if defined($active);
        move_tree($tree, $failed) if defined($staged);
        return 1;
    });
    install_checkpoint($plan, 'FAILED_RETAINED');
    return 1;
}

sub install_fresh_db {
    my ($tree, $cfg) = @_;
    return owner_file_call(sub {install_fresh_db($tree, $cfg)}) if $home_fs && !$fs_child;
    fail('fresh database can only be created after canonical alias is set')
        unless (realpath('/spider')//'') eq $tree;
    fail('fresh database path is not the selected installation') unless $tree eq $root;
    my $data = "$tree/local_data";
    fail('unsafe local_data') unless -d $data && !-l $data;
    opendir my $dh, $data or fail('inspect new database directory');
    my @files = grep {$_ ne '.' && $_ ne '..' && $_ ne '.gitignore'
        && $_ ne '.cvsignore'} readdir $dh;
    closedir $dh;
    fail('fresh database initialization would overwrite existing data') if @files;
    # The actual DXUser initializer can import legacy data from data/ too.
    for my $dir ("$tree/data", $data) {
        for my $file (qw(
            users.v2 users.v3 users.v3j dxusers.db dxusers.db-wal dxusers.db-shm
            dxusers.db-journal
        )) {
            fail('existing user data found in clean installation') if exists_path("$dir/$file");
        }
    }
    fail('missing real create_sysop.pl') unless -f "$tree/perl/create_sysop.pl"
        && !-l "$tree/perl/create_sysop.pl";
    my @prefix = $fs_child?():install_account_prefix($owner, $group);
    run('timeout', '180', @prefix, 'env', 'DXSPIDER_ROOT=/spider', $^X,
        "$tree/perl/create_sysop.pl");
    my $db = "$data/dxusers.db";
    fail('create_sysop did not produce a regular SQLite database') unless -f $db && !-l $db;
    my ($ok, $raw) = capture_status('timeout', '30', @prefix, $^X, '-MDBI', '-MDBD::SQLite', '-e',
        'my ($db,$node,$sysop)=@ARGV; my $h=DBI->connect("dbi:SQLite:dbname=$db","","",{RaiseError=>1,PrintError=>0,sqlite_open_flags=>1}); my ($ok)=$h->selectrow_array("PRAGMA integrity_check"); die "integrity" unless $ok eq "ok"; for my $call ($node,$sysop) {my ($n)=$h->selectrow_array("SELECT count(*) FROM users WHERE call=?",undef,$call); die "missing identity" unless $n==1} $h->disconnect; print "OK\n";',
        $db, $cfg->{node}, $cfg->{sysop});
    fail('new user database failed integrity or identity verification') unless $ok
        && $raw eq "OK\n";
    return 1;
}

# The private-lab runner and authorized production UI use the same sequence.

sub install_publish_and_initialize {
    my ($cfg, $prepared, $account) = @_;
    my $plan;
    my $ok = eval {
        $plan = install_publish_tree($cfg, $prepared, $account, '/spider');
        install_checkpoint($plan, 'DATABASE');
        install_fresh_db($root, $cfg);
        install_checkpoint($plan, 'DATABASE_READY');
        1;
    };
    if (!$ok) {
        my $err = $@;
        # The state and identity were persisted before publication. Never
        # discard an incomplete candidate or remove an unrelated destination.
        my $recover_ok = eval {
            if (defined($work) && $work eq $prepared->{path}) {
                my $p = $json->decode(read_file("$work/install-plan.json"));
                install_retain_failed_publication($p)
                    if $p->{state} =~ /\A(?:ACTIVATING|PUBLISHED|DATABASE|DATABASE_READY)\z/;
            }
            1;
        };
        print STDERR "INSTALL RECOVERY REQUIRED: $@" unless $recover_ok;
        die $err;
    }
    return $plan;
}

# The service unit is a separate durable resource. Record its inode before
# publication, never replace an existing unit, and refuse unknown drop-ins.

sub install_service_name {
    return 'dxspider.service';
}

sub install_unit_path {
    return '/etc/systemd/system/'.install_service_name();
}

sub install_unit_file_identity {
    my ($path) = @_;
    my @s = lstat($path);
    return undef unless @s;
    fail('unsafe fresh service file') unless S_ISREG($s[2]) && $s[4] == 0 && !($s[2]&0022);
    return "$s[0]:$s[1]";
}

sub install_service_preflight {
    my ($cfg) = @_;
    fail('canonical /spider is already occupied') if exists_path('/spider');
    if (LIVE_ENABLED) {
        my @found = ui_discover(@scan_roots);
        fail('existing installation discovered: '.join(', ', @found)) if @found;
        my ($ok, $records) = service_catalogue();
        fail('complete systemd inventory unavailable') unless $ok;
        fail('existing DXSpider-family systemd service detected')
            if grep {scalar(service_entry_points($_))} @$records;
    }
    fail('installation destination already occupied') if exists_path($cfg->{destination});
    for my $p (all_pids()) {
        my $q = proc_info($p) or next;
        fail('existing DXSpider process detected') if manual_candidate($q);
    }
    # Manual installations also must not collide with a configured standard unit.
    for my $role (@start) {
        my $v = unit_info($role);
        fail("existing or unverified service: $role") unless $v->{ok}
            && ($v->{LoadState}//'') eq 'not-found' && unit_stopped($v);
    }
    fail('standard service file already exists') if exists_path(install_unit_path());
    for my $l (tcp_listeners()) {
        fail('Telnet port already in use') if $l->{port} == $cfg->{port};
        fail('DXSpider internal port already in use') if $l->{port} == 27754;
    }
    return 1;
}

sub install_checked_service {
    my ($plan) = @_;
    my $path = install_unit_path();
    fail('service file identity changed') unless same(install_unit_file_identity($path),
        $plan->{service_id});
    fail('service file contents changed')
        unless sha256_hex(read_file($path)) eq $plan->{service_sha};
    my $v = unit_info('spider', install_service_name());
    fail('service association cannot be verified') unless unit_definition_ok($v)
        && ($v->{FragmentPath}//'') eq $path;
    my $drop = capture('timeout', '10', 'systemctl', 'show', install_service_name(),
        '--property=DropInPaths', '--value');
    fail('unexpected service drop-in') if $drop =~ /\S/;
    if (defined $plan->{unit_sha}) {
        fail('effective service definition changed') unless same($v->{unit_sha}, $plan->{unit_sha});
    }
    return $v;
}

sub install_start_systemd {
    my ($cfg, $plan) = @_;
    fail('fresh service requires initialized database') unless $plan->{state} eq 'DATABASE_READY';
    my $path = install_unit_path();
    my $dir = dirname($path);
    my $p = $dir;
    while (1) {
        my @s = lstat($p);
        fail('untrusted service directory') unless @s && S_ISDIR($s[2]) && $s[4] == 0
            && !($s[2]&0022);
        last if $p eq '/';
        $p = dirname($p);
    }
    my $v = unit_info('spider', install_service_name());
    fail('service already exists; not replaced') unless !exists_path($path) && $v->{ok}
        && ($v->{LoadState}//'') eq 'not-found' && unit_stopped($v);
    my $raw = install_service_text($cfg, $root);
    my $temp = "$dir/.dxs-manager-".substr(random_token(), 0, 24).'.unit';
    write_file($temp, $raw);
    chmod(0644, $temp) or fail('service file chmod');
    open my $unit_fh, '<', $temp or fail('open new service file');
    $unit_fh->sync or fail('sync new service file');
    close $unit_fh or fail('close new service file');
    sync_dir($dir);
    $plan->{service_temp} = $temp;
    $plan->{service_id} = install_unit_file_identity($temp);
    $plan->{service_sha} = sha256_hex($raw);
    install_checkpoint($plan, 'SERVICE_WRITING');
    # link() fails if a different operator creates the unit in the meantime.
    link($temp, $path) or fail("publish service file: $!");
    sync_dir($dir);
    unlink($temp) or fail('remove service staging name');
    sync_dir($dir);
    install_checkpoint($plan, 'SERVICE_PUBLISHED');
    run('timeout', '30', 'systemctl', 'daemon-reload');
    $v = install_checked_service($plan);
    fail('new service unexpectedly active') unless unit_stopped($v);
    $plan->{unit_sha} = $v->{unit_sha};
    install_checkpoint($plan, 'SERVICE_STARTING');
    ui_event('Starting DXSpider service');
    run('timeout', '90', 'systemctl', 'start', install_service_name());
    my $end = time+90;
    my $identity;
    while (time<$end) {
        $v = install_checked_service($plan);
        fail('new service failed to start') if ($v->{ActiveState}//'') eq 'failed';
        if ($v->{confirmed}) {
            $identity = unit_identity($v);
            my $ok = eval {probe_unit('spider', {type => 'prompt', port => $cfg->{port},
                    expect => 'login: '}, $v); 1};
            last if $ok;
            undef $identity;
        }
        sleep .5;
    }
    fail('new service did not return verified login prompt') unless defined $identity;
    for (1..3) {
        sleep 1;
        $v = install_checked_service($plan);
        fail('new service restarted during verification') unless $v->{confirmed}
            && unit_identity($v) eq $identity;
    }
    probe_unit('spider', {type => 'prompt', port => $cfg->{port}, expect => 'login: '}, $v);
    install_checkpoint($plan, 'SERVICE_ENABLING');
    run('timeout', '30', 'systemctl', 'enable', install_service_name());
    my $enabled = capture('timeout', '10', 'systemctl', 'is-enabled', install_service_name());
    fail('service not enabled') unless $enabled eq "enabled\n";
    $v = install_checked_service($plan);
    fail('service identity changed after enabling') unless $v->{confirmed}
        && unit_identity($v) eq $identity;
    $plan->{service_identity} = $identity;
    install_checkpoint($plan, 'INSTALL_COMMITTED');
    ui_event('[ OK ] DXSpider service started, verified and enabled');
    return 1;
}

# Undo only the unit published by this installation, then retain the tree.
# If unit identity or quiescence cannot be established, leave everything in place.

sub install_recover_service {
    my ($plan) = @_;
    my $path = install_unit_path();
    my $temp = $plan->{service_temp}//'';
    my $dir = dirname($path);
    fail('invalid unit staging path') unless $temp=~m{\A\Q$dir\E/\.dxs-manager-[0-9a-f]{24}\.unit\z};
    if (exists_path($path)) {
        fail('unknown service file; recovery requires review')
            unless same(install_unit_file_identity($path), $plan->{service_id})
            && sha256_hex(read_file($path)) eq $plan->{service_sha};
        run('timeout', '30', 'systemctl', 'daemon-reload');
        my $v = install_checked_service($plan);
        run('timeout', '90', 'systemctl', 'stop', install_service_name()) unless unit_stopped($v);
        fail('new service still running') unless unit_stopped(install_checked_service($plan));
        run('timeout', '30', 'systemctl', 'disable', install_service_name());
        install_checked_service($plan);
        install_checkpoint($plan, 'SERVICE_WITHDRAWING');
        unlink($path) or fail('cannot withdraw own service file');
        sync_dir($dir);
        run('timeout', '30', 'systemctl', 'daemon-reload');
    } elsif ($plan->{state} eq 'SERVICE_WITHDRAWING') {
        # A previous process may have unlinked our unit before daemon-reload.
        run('timeout', '30', 'systemctl', 'daemon-reload');
    }
    if (exists_path($temp)) {
        fail('unknown service staging file') unless same(install_unit_file_identity($temp),
            $plan->{service_id})
            && sha256_hex(read_file($temp)) eq $plan->{service_sha};
        unlink($temp) or fail('remove own service staging file');
        sync_dir($dir);
    }
    my $v = unit_info('spider', install_service_name());
    fail('service absence not confirmed') unless $v->{ok} && ($v->{LoadState}//'') eq 'not-found'
        && unit_stopped($v);
    install_checkpoint($plan, 'DATABASE_READY');
    install_retain_failed_publication($plan);
    return 1;
}

sub install_finish_startup {
    my ($cfg, $plan) = @_;
    fail('database not initialized') unless $plan->{state} eq 'DATABASE_READY';
    if ($cfg->{startup} eq 'manual') {
        install_checkpoint($plan, 'INSTALL_COMMITTED');
        ui_event('[ OK ] Installation ready; manual startup pending');
        return 1;
    }
    fail('unknown startup mode') unless $cfg->{startup} eq 'systemd';
    my $ok = eval {install_start_systemd($cfg, $plan); 1};
    return 1 if $ok;
    my $e = $@;
    my $r = eval {
        if ($plan->{state} =~ /\ASERVICE_/) {
            install_recover_service($plan);
        }
        elsif ($plan->{state} eq 'DATABASE_READY') {
            install_retain_failed_publication($plan);
        }
        1;
    };
    print STDERR "INSTALL RECOVERY REQUIRED: $@" unless $r;
    die $e;
}

# An occupied global command is preserved and reported, never overwritten.
sub install_aux_links {
    my ($physical, $dir, $alias) = @_;
    protected_ancestors($dir);
    fail('canonical alias changed') unless (realpath($alias)//'') eq $physical;
    my %helpers = ('dx' => 'console.pl');
    opendir my $dh, "$physical/perl" or fail('cannot inspect console helpers');
    for my $name (readdir $dh) {
        $helpers{$name} = $name if $name =~  /\A[A-Za-z0-9_.-]+dbg\z/;
    }
    closedir $dh;
    my @warnings;
    for my $name (sort keys %helpers) {
        my $source = "$physical/perl/$helpers{$name}";
        my $target = "$alias/perl/$helpers{$name}";
        my $dest = "$dir/$name";
        if (!-f $source || -l $source || !-x $source) {
            push @warnings, "Helper unavailable: $name";
            next;
        }
        if (exists_path($dest)) {
            next if -l $dest && (readlink($dest)//'') eq $target;
            push @warnings, "Existing command preserved: $dest";
            next;
        }
        if (!symlink($target, $dest)) {
            push @warnings, "Helper not created: $dest ($!)";
            next;
        }
        sync_dir($dir);
    }
    return \@warnings;
}

sub install_execute {
    my ($cfg, $home, $actions) = @_;
    fail('production installation disabled') unless LIVE_ENABLED;
    fail('root required') unless $> == 0;
    # The global lock prevents two fresh installs racing for /spider or the
    # standard service. It is outside all account-managed directories.
    my $state_dir = manager_state_directory(1);
    my $guard = install_global_lock($state_dir);
    fail('previous installation requires recovery') if install_pending_read($state_dir);
    local $SIG{INT} = sub {fail('installation interrupted')};
    local $SIG{TERM} = sub {fail('installation terminated')};
    my @pw = getpwnam($cfg->{user});
    install_service_text($cfg, $cfg->{destination}) if $cfg->{startup} eq 'systemd';
    install_parent_plan($cfg->{destination}, $home, @pw?$pw[2]:undef);
    install_service_preflight($cfg);
    my @gr = getgrnam($cfg->{group});
    my $member = @pw && @gr && ($pw[3] == $gr[2] || grep {$_ eq $cfg->{user}} split /\s+/,
        $gr[3]//'');
    install_account_commands($cfg, @pw?\@pw:undef, @gr?\@gr:undef, $member);
    my $anchor = install_path_anchor($cfg->{destination});
    my $scratch = "$anchor/.dxs-dependencies-".substr(random_token(), 0, 24);
    mkdir($scratch, 0700) or fail('cannot create dependency workspace');
    sync_dir($anchor);
    $root = "$anchor/.dxs-install-space";
    my ($mb, $mn) = capacity_margin(0, 0);
    capacity_check($mb, $mn, 1);
    ui_event('Installing and verifying required dependencies');
    install_dependencies($actions, $scratch);
    ui_event('[ OK ] Runtime dependencies verified');
    install_service_preflight($cfg);
    ui_event('Preparing SYSOP account and group');
    my $account = install_create_accounts($cfg);
    ui_event('[ OK ] SYSOP account and group ready');
    if ($account->{new_account}) {
        # useradd creates a locked login. Do not obtain or log a password
        # inside the redirected technical output. The account can run systemd.
        print "NEW_ACCOUNT login password not set; account retained on any failure\n";
    }
    fail('created account HOME differs from selected default') if $account->{new_account}
        && under($cfg->{destination}, $home) && $account->{home} ne $home;
    install_account_parent($cfg->{destination}, $account);
    ui_event('Downloading and configuring DXSpider');
    my $prepared = install_prepare_candidate($cfg);
    ui_event('[ OK ] Candidate verified and configured');
    install_service_preflight($cfg);
    install_pending_register($state_dir, $prepared, $cfg->{destination});
    my $plan = install_publish_and_initialize($cfg, $prepared, $account);
    ui_event('[ OK ] User database initialized and verified');
    install_finish_startup($cfg, $plan);
    install_pending_clear($state_dir, '/spider');
    my $warnings = eval {install_aux_links($cfg->{destination}, '/usr/local/bin', '/spider')};
    $warnings = ['Console helpers not configured: '.$@] if $@;
    ui_event('[WARNING] '.ui_safe($_)) for @$warnings;
    return {plan => $plan, prepared => $prepared, account => $account, warnings => $warnings};
}

sub install_required_input {
    my ($prompt, $default, $validator) = @_;
    while (1) {
        my $v = ui_ask($prompt, $default);
        return undef unless defined $v;
        my $ok = eval { $validator ? $validator->($v) : (length($v)
            && $v !~ /[\x00-\x1f\x7f]/ ? $v : fail('invalid value')) };
        return $ok if defined($ok) && !$@;
        print "  Invalid value. Please try again.\n";
    }
}

sub ui_install {
    my (@found) = @_;
    ui_section('EXISTING INSTALLATIONS');
    if (@found) {
        print "  Existing installations will not be overwritten:\n";
        print '  ', ui_safe($_), "\n" for @found;
        print "\n  DXSpider uses /spider in its source. A second independent\n  running instance cannot be assumed safe.\n";
        if (LIVE_ENABLED) {
            print "  Installation cancelled. Use Update for an existing node.\n";
            return 1;
        }
        return 0 unless ui_yes('Prepare a separate installation without activating it?', 0);
    } else {
        print "  No DXSpider installation detected.\n";
    }
    ui_section('INSTALLATION SETTINGS');
    my %c;
    $c{user} = install_required_input('System user', 'sysop', \&install_account_name); return 0
        unless defined $c{user};
    $c{group} = install_required_input('System group', 'spider', \&install_account_name); return 0
        unless defined $c{group};
    my @pw = getpwnam($c{user});
    my $home = @pw?$pw[7]:"/home/$c{user}";
    $c{destination} = install_required_input('Installation directory', "$home/spider",
        sub {install_path_anchor($_[0]); return $_[0]}); return 0 unless defined $c{destination};
    $c{branch} = install_required_input('Branch (mojo or test)', 'mojo', sub {fail('invalid branch')
        unless $_[0] =~ /\A(?:mojo|test)\z/; return $_[0]}); return 0 unless defined $c{branch};
    $root = $c{destination};
    ui_open_log('install');
    my ($os, $actions) = install_distro(optional_read('/etc/os-release'));
    print {$ui_log} 'Distribution actions: ', $json->encode(install_dependency_commands($actions)),
        "\n";
    ui_section('DXCLUSTER CONFIGURATION');
    for my $item (['node', 'DXCluster node callsign', \&install_callsign], ['sysop',
        'SYSOP callsign',
        sub {my $a = install_callsign($_[0]); fail('must differ from node') if $a eq $c{node};
        return $a}], ['name', 'SYSOP name'], ['email', 'Email address'], ['locator',
        'Six-character Maidenhead locator', sub {return (install_locator_center($_[0]))[0]}],
        ['qth',
        'QTH']) {
        $c{$item->[0]} = install_required_input($item->[1], undef, $item->[2]); return 0
            unless defined $c{$item->[0]};
    }
    $c{port} = install_required_input('IPv4 Telnet port', '7300', sub {fail('invalid port')
        unless $_[0] =~ /\A[0-9]+\z/ && $_[0] >= 1 && $_[0] <= 65535 && $_[0] != 27754;
        return 0+$_[0]}); return 0 unless defined $c{port};
    $c{startup} = install_required_input('Startup (systemd or manual)', 'systemd',
        sub {fail('invalid startup type') unless $_[0] =~ /\A(?:systemd|manual)\z/; return $_[0]});
        return 0 unless defined $c{startup};
    ui_section('INSTALLATION PLAN');
    print {$ui_log} 'Install configuration: ',
        $json->encode({map {$_ => $c{$_}} qw(destination user group branch node sysop locator port startup)}), "\n";
    printf "  %-18s %s\n", 'Distribution:', ui_safe($os);
    printf "  %-18s %s\n", 'Installation:', ui_safe($c{destination});
    printf "  %-18s %s:%s\n", 'User/group:', $c{user}, $c{group};
    printf "  %-18s %s\n", 'Branch:', $c{branch};
    printf "  %-18s %s\n", 'Telnet port:', $c{port};
    printf "  %-18s %s\n", 'Startup:', $c{startup};
    print "\n  Latitude/longitude use the locator centre (DXBearing formula).\n  Exact download size will be measured after cloning.\n";
    print "  Only candidate preparation is enabled. No accounts, packages,\n  symlinks, databases or services will be created on the host.\n" unless LIVE_ENABLED;
    my $managed = eval { install_parent_plan($c{destination}, $home, @pw?$pw[2]:undef); 1 };
    if (!$managed) {
        print "\n  Activation is blocked: the selected physical directory does not meet\n  the protected transaction layout requirements. HOME permissions will not be changed.\n";
        print {$ui_log} "INSTALL LAYOUT BLOCK: $@" if $ui_log;
    }
    if (LIVE_ENABLED) {
        return 1 unless $managed;
        print "\n  The manager will install required system packages and verify Perl modules, prepare the\n  SYSOP account, configure the node and initialize its database.\n";
        print "  DXSpider will be enabled and started by systemd.\n" if $c{startup} eq 'systemd';
        print "  Manual startup will remain pending.\n" if $c{startup} eq 'manual';
        print "  DXWeb and DXWeb Admin are not installed by this operation.\n  Packages and accounts created during installation are retained on failure.\n";
        return 0 unless ui_yes('Perform clean installation now?', 0);
        ui_section('INSTALLING DXSPIDER');
        my ($ok, $result) = ui_step('Running clean installation', sub {install_execute(\%c, $home,
            $actions)});
        ui_section('INSTALLATION RESULT');
        return 1 unless $ok;
        ui_result('[ OK ] DXSpider installed successfully');
        print '  Installation: ', ui_safe($c{destination}), "\n";
        print '  Version/build: ', ui_safe($result->{prepared}{describe}), "\n";
        print '  DXSpider: ', ($c{startup} eq 'systemd'?'RUNNING (systemd)':'MANUAL START PENDING'),
            "\n";
        print "  New account: login password not set. Use passwd ".ui_safe($c{user})." if interactive login is needed.\n" if $result->{account}{new_account};
        print "  WARNING: ", ui_safe($_), "\n" for @{$result->{warnings}//[]};
        return 0;
    }
    return 0 unless ui_yes('Download and prepare the configured candidate?', 0);
    ui_section('PREPARING INSTALLATION');
    my ($ok, $result) = ui_step('Preparing clean installation candidate',
        sub {install_prepare_candidate(\%c)});
    return 1 unless $ok;
    print '  Verified candidate version: ', ui_safe($result->{describe}), "\n";
    print '  Candidate size: ', ui_gib($result->{bytes}), "\n";
    print '  Private staging directory: ', ui_safe($result->{path}), "\n";
    ui_result('[SKIPPED] System installation is not enabled.');
    return 0;
}

# ==========================================================================
# 20. Interactive entry point
# ==========================================================================

sub interactive {
    print "\n==============================================================\n";
    print " DXSpider Manager ", VERSION, " - Installation, update and restore\n";
    print "==============================================================\n";
    print LIVE_ENABLED ? " LIVE - explicit confirmation required\n" : " PREVIEW - preparation only\n";
    my ($os) = optional_read('/etc/os-release') =~  /^PRETTY_NAME="?([^"\n]+)"?$/m;
    print ' OS: ', ui_safe($os // 'unknown'), "\n Perl: $^V\n";

    while (1) {
        ui_section('MAIN MENU');
        print "  [I] Install DXSpider\n  [U] Update DXSpider\n";
        print "  [R] Restore previous installation or backup\n  [Q] Quit\n\n";
        my $a = ui_ask('Select operation', 'U');
        return 0 if !defined($a) || $a =~  /^q$/i;
        unless ($a =~  /^[iur]$/i) {
            print "Invalid option.\n";
            next;
        }
        my $action = $a =~  /^i$/i ? 'install' : $a =~  /^u$/i ? 'update' : 'restore';
        my $state_dir;
        my $pending;
        my $pending_ok = eval {
            $state_dir = manager_state_directory(0);
            $pending = install_pending_read($state_dir);
            1;
        };
        if (!$pending_ok) {
            ui_result('[FAIL] '.ui_safe($@));
            return 1;
        }
        if ($pending) {
            $root = $pending->{destination};
            ui_open_log($action);
            ui_section('INTERRUPTED INSTALLATION');
            print '  Installation: ', ui_safe($root), "\n  Workspace: ",
                ui_safe($pending->{workspace}),
                "\n";
            my $r = 1;
            if ($action ne 'restore') {
                print "  Select Restore to recover this installation before another operation.\n";
            } elsif (!LIVE_ENABLED) {
                print "  Production recovery is unavailable in preview mode. No changes made.\n";
            } elsif (ui_yes('Recover interrupted installation and retain its files?', 0)) {
                my ($ok, $status) = ui_step('Recovering interrupted installation', sub {
                    my $guard = install_global_lock($state_dir);
                    my $now = install_pending_read($state_dir);
                    fail('pending installation changed') unless $now && same($now->{workspace_id},
                        $pending->{workspace_id});
                    return install_recover_registered($state_dir, '/spider');
                });
                print "  Recovery result: $status\n" if $ok;
                $r = $ok?0:1;
            } else { $r = 0; }
            print {$ui_log} "RESULT exit=$r finished=", time, "\n";
            print "  Operation log: $ui_logpath\n";
            return $r;
        }
        ui_section('SELECT INSTALLATION');
        print "Detecting DXSpider installations...\n";
        my @found = ui_discover(@scan_roots);
        if ($action eq 'install') {
            my $r = 0;
            my $ok = eval { $r = ui_install(@found); 1 };
            if (!$ok) {
                ui_result('[FAIL] '.ui_safe($@));
                $r = 1;
            }
            print {$ui_log} "RESULT exit=$r finished=", time, "\n" if $ui_log;
            print "  Operation log: $ui_logpath\n" if $ui_logpath;
            return $r;
        }
        if ($action eq 'restore') {
            my %seen = map {$_ => 1} @found;
            for my $p (ui_standard_paths(), $installation, @scan_roots) {
                my $r = ui_recovery_path($p);
                next unless defined($r) && !$seen{$r}++;
                push @found, $r;
                $ui_discovery_reason{$r}{'interrupted transaction'} = 1;
            }
        }
        my $selected;
        $selected = ui_choose_for($action eq 'restore'?'recovery':$action, @found);
        next unless defined $selected;

        # Once an operation is selected and executed, return to the shell.
        my $result = 0;
        my $ok = eval {
            $fixture = 0;
            $root = validate_root($selected, $action eq 'restore');
            $work = undef;
            $j = undef;
            ui_open_log($action);
            if ($action eq 'restore') {
                $result = ui_restore();
            }  else {
                my ($read_ok, $v) = ui_step('Reading installed Git version', sub {
                    my $version = ui_revision($root);
                    print $json->encode($version), "\n";
                    return $version;
                });
                fail('cannot read installed version') unless $read_ok;
                ui_section('INSTALLED VERSION');
                print "Selected installation: ", ui_safe($root), "\n";
                print "  Installed branch: ", ui_safe($v->{branch}), "\n";
                print "  Installed version/build: ", ui_safe($v->{describe}), "\n";
                print "  Installed revision: ", substr(ui_safe($v->{head}), 0, 12), "\n";
                $result = ui_update_plan($v) // 0;
            }
            1;
        };
        if (!$ok) {
            ui_result('[FAIL] ' . ui_safe($@));
            $result = 1;
        }
        print {$ui_log} "RESULT exit=$result finished=", time, "\n" if $ui_log;
        print "  Operation log: $ui_logpath\n" if $ui_logpath;
        return $result;
    }
}


# ==========================================================================
# 21. Command line help and dispatch
# ==========================================================================

sub usage {
    print <<'HELP';
DXSpider Manager 1.1 — interactive install, update and restore
  perl dxspider-manager.pl            Production menu; root and terminal required
  perl dxspider-manager.pl --preview  Preparation only (no service actions)
  perl dxspider-manager.pl --live     Explicit production mode (compatibility)
  --mode interactive [--scan-root ABSOLUTE_DIR] [--installation PATH]
  --mode host-plan --installation /spider --branch mojo|test [--backup] [--reserve-gib N]
  --mode integration-check --installation /spider --branch mojo|test [--check-remote] [--probe-config FILE]
      [--manual-launch-dir ABSOLUTE_DIR] [--spider-port N] [--web-port N] [--admin-port N]
  --mode prepare --installation /spider --branch mojo|test [--backup] [--accept-local-changes]
  --mode inspect --installation /spider
  --mode archive --installation /spider (retain a finished or unused transaction)
  --mode selftest|manual-selftest --base /root/dxs-updater-test-UNIQUE
  --mode systemd-selftest --base /root/dxs-updater-systemd-UNIQUE
  --mode systemd-fixture-cleanup --base /root/dxs-updater-systemd-UNIQUE/CASE
  --mode git-prepare-check --base /root/dxs-updater-git-UNIQUE --installation /spider --branch mojo|test
  --mode fixture-seed|fixture-prepare|fixture-update|fixture-recover|fixture-inspect|fixture-archive|fixture-stop --base ABSOLUTE_FIXTURE
  --mode update|recover : disabled; use the interactive menu and confirm
  --mode rehearse : disabled; no hot copy of real installation
Only successful SQLite verification scratch is removed automatically. Fixture paths must be newly created, private and outside /spider and /tmp.
HELP
}
# MAIN DISPATCH (test boundary)
if ($help) {
    usage();
    exit 0
}
fail('observation options only for integration-check or explicit update') if ($manual_launch_dir
    || $spider_port || $web_port || $admin_port) && $mode ne 'integration-check'
    && $mode ne 'update'
    && $mode ne 'fixture-update';
fail('invalid observation port') if grep {$_<0||$_>65535} ($spider_port, $web_port, $admin_port);
fail('invalid branch') unless $branch eq 'mojo' || $branch eq 'test';
fail('invalid reserve') unless $reserve >= 0 && $reserve <= 1000;
fail('fault injection only in fixture') if length($fault) && $mode !~ /^fixture-/;
fail('--live and --preview are mutually exclusive') if $live_requested && $preview_requested;
fail('--live and --preview are restricted to the interactive menu')
    if ($live_requested || $preview_requested) && $mode ne 'interactive';
if ($mode eq 'interactive' && !$preview_requested) {
    fail('production menu requires root and an interactive terminal; use --preview for preparation')
        unless $> == 0 && -t STDIN && -t STDOUT;
    $live_enabled = 1;
}
if ($mode eq 'interactive') {
    exit interactive()
}
if ($mode eq 'worker') {
    worker();
    exit 0
}
if ($mode eq 'systemd-selftest') {
    tools_check();
    systemd_selftest();
    exit 0
}
if ($mode eq 'systemd-fixture-cleanup') {
    fixture_context();
    fail('not a systemd fixture') unless $systemd_fixture;
    systemd_fixture_cleanup();
    exit 0
}
if ($mode eq 'selftest') {
    tools_check();
    selftest();
    exit 0
}
if ($mode eq 'manual-selftest') {
    tools_check();
    manual_selftest();
    exit 0
}
if ($mode eq 'fixture-seed') {
    tools_check();
    fixture_seed();
    exit 0
}
if ($mode eq 'fixture-stop') {
    fixture_cleanup_workers();
    exit 0
}
if ($mode =~  /\Afixture-(?:prepare|update|recover|inspect|archive)\z/) {
    fixture_context();
    acquire($mode eq 'fixture-prepare');
    if ($mode eq 'fixture-prepare') {
        prepare()
    } elsif ($mode eq 'fixture-update') {
        do_update()
    } elsif ($mode eq 'fixture-recover') {
        do_recover()
    } elsif ($mode eq 'fixture-archive') {
        archive_tx()
    } else {
        inspect_tx()
    }
    exit 0
}
if ($mode eq 'git-prepare-check') {
    setup_live();
    git_prepare_check();
    exit 0
}
if ($mode eq 'rehearse') {
    fail('hot copy disabled; use isolated selftest; no real writers may be stopped')
}
fail('unknown mode')
    unless $mode =~  /\A(?:host-plan|integration-check|prepare|inspect|archive|update|recover)\z/;
fail('production activation/recovery disabled; explicit approval and host validation required')
    if ($mode eq 'update' || $mode eq 'recover') && !LIVE_ENABLED;
setup_live();
if ($mode eq 'integration-check') {
    exit integration_check()
}
if ($mode eq 'host-plan') {
    print "DXSpider Updater ", VERSION,
        " HOST PLAN (read only)\nINSTALLATION $root\nBRANCH $branch\nOWNER uid=$owner gid=$group\nPERL $^V\n";
    my $os = optional_read('/etc/os-release');
    for my $line (split /\n/, $os) {
        print "OS $line\n" if $line =~  /\A(?:ID|VERSION_ID)=/
    }
    my ($blocked, $u) = host_inventory();
    my $ok = eval{
        tools_check();
        no_mounts($root);
        capacity(1);
        my $d = local_changes($root);
        print 'LOCAL CHANGES outside persistence: ',
            length($d)?($d eq 'NO_GIT'?'NO_GIT':scalar(split /\0/, $d)):'none', "\n";
        1
    };
    print STDERR $@ unless $ok;
    print "REMOTE FRESHNESS UNKNOWN (host-plan does not contact remote)\n";
    print "RESULT BLOCK; live activation disabled; functional probes and manual restart must be validated\n";
    exit 2;
}
acquire($mode eq 'prepare');
if ($mode eq 'prepare') {
    prepare()
} elsif ($mode eq 'inspect') {
    inspect_tx()
} elsif ($mode eq 'archive') {
    archive_tx()
} elsif ($mode eq 'update') {
    do_update()
} else {
    do_recover()
}
