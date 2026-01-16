#
# badnode.pl - Rebuild badnode entries in memory (DXProt::badnode, a DXHash)
#              from disk sources: badnode.new + badnode.local + any badnode.* files in local_data,
#              then write local_data/badnode in DXHash dumped format (bless({..}, 'DXHash')).
#
# Output:
#   Rebuilt disk -> memory
#   Before rebuild: <n>
#   Loaded from disk: <n>
#   Removed: <n>
#   Added: <n>
#   Final total: <n>
#
# Privilege: priv >= 9
#
# Kin EA3CV <ea3cv@cronux.net>
#
# 20260116 v1.3
#

use strict;
use warnings;

use DXUtil;

my ($self, $line) = @_;
my @out;

return (1, $self->msg('e5')) if $self->priv < 9;

# ---------------- helpers ----------------

sub _badnode_obj {
    # DXProt.pm defines $badnode in package DXProt
    no strict 'refs';
    return $DXProt::badnode;
}

sub _is_node_key {
    my ($k) = @_;
    return 0 unless defined $k && length $k;
    return 0 if $k eq 'name';
    return 1;
}

sub _mem_nodes_hash {
    my ($bn) = @_;
    my %h;

    return %h unless $bn && ref($bn) eq 'DXHash';

    for my $k (keys %{$bn}) {
        next unless _is_node_key($k);
        my $v = $bn->{$k};
        next unless defined $v && $v =~ /^\d+$/;   # epoch
        $h{$k} = $v;
    }
    return %h;
}

sub _read_list_file {
    my ($path) = @_;
    my @nodes;

    return @nodes unless defined $path && -e $path;

    open(my $fh, '<', $path) or return @nodes;
    while (my $l = <$fh>) {
        chomp $l;
        $l =~ s/\r$//;
        $l =~ s/^\s+|\s+$//g;
        next if $l eq '';
        next if $l =~ /^\s*\#/;

        $l = uc($l);

        # Accept node names like DB0ERF-5, 9M2PJU-1, etc.
        next unless $l =~ /^[A-Z0-9\-]+$/;

        push @nodes, $l;
    }
    close $fh;

    return @nodes;
}

sub _ensure_badnode_local {
    my ($mem_href) = @_;

    my $fn = localdata("badnode.local");
    return (0, 0) unless defined $fn && length $fn;

    # If it exists, do nothing
    return (1, 0) if -e $fn;

    # Create it from current in-memory nodes snapshot
    my @nodes = sort keys %{ $mem_href || {} };

    if (open(my $fh, '>', $fn)) {
        for my $n (@nodes) {
            next unless defined $n && length $n;
            print $fh "$n\n";
        }
        close $fh;
        return (1, scalar(@nodes));
    }

    # Non-fatal: continue normal execution even if we can't create it
    return (0, 0);
}

sub _read_all_disk_nodes {
    my %seen;
    my @all;

    # 1) Base list: badnode.new
    my $newfn = localdata("badnode.new");
    for my $n (_read_list_file($newfn)) {
        next if $seen{$n}++;
        push @all, $n;
    }

    # 2) Extra lists: any badnode.* in local_data (except .new, .run)
    #    NOTE: badnode.local IS intentionally included here.
    eval {
        my $dir;
        opendir($dir, $main::local_data) or die "opendir($main::local_data): $!";
        while (my $fn = readdir $dir) {
            next unless my ($suffix) = $fn =~ /^badnode\.(\w+)$/;

            next if $suffix eq 'new';
            next if $suffix eq 'run';

            my $path = "$main::local_data/$fn";
            next unless -f $path;

            for my $n (_read_list_file($path)) {
                next if $seen{$n}++;
                push @all, $n;
            }
        }
        closedir $dir;
    };

    return @all;
}

sub _write_badnode_hashfile {
    my ($name, $href) = @_;
    my $fn = localdata("badnode");

    open(my $fh, '>', $fn) or return 0;

    print $fh "bless( {\n";

    for my $k (sort keys %{$href}) {
        my $v = $href->{$k};
        next unless defined $v && $v =~ /^\d+$/;

        my $key_out = ($k =~ /^[A-Z0-9]+$/) ? $k : "'" . $k . "'";
        print $fh "  $key_out => $v,\n";
    }

    print $fh "  name => '$name',\n";
    print $fh "}, 'DXHash' )\n";

    close $fh;
    return 1;
}

# ---------------- main ----------------

my $bn = _badnode_obj();

# 1) Snapshot memory BEFORE rebuild
my %mem = _mem_nodes_hash($bn);
my $before_mem = scalar keys %mem;

# 1b) Ensure badnode.local exists (create it from memory snapshot if missing)
my ($ok_local, $created_n) = _ensure_badnode_local(\%mem);
push @out, "Created badnode.local from memory: $created_n" if $ok_local && $created_n;

# 2) Read disk sources (badnode.new + badnode.local + badnode.*)
my @disk_nodes = _read_all_disk_nodes();
my $loaded_from_disk = scalar @disk_nodes;

# 3) Build final set ONLY from disk.
#    Preserve old timestamps for entries that still exist; new entries get "now".
my %final;
my $now = time;

for my $n (@disk_nodes) {
    next unless defined $n && length $n;
    $final{$n} = exists $mem{$n} ? $mem{$n} : $now;
}

# 4) Replace in-memory DXProt::badnode content (purge removed entries)
if ($bn && ref($bn) eq 'DXHash') {
    for my $k (keys %{$bn}) {
        delete $bn->{$k} unless $k eq 'name';
    }
    for my $k (keys %final) {
        $bn->{$k} = $final{$k};
    }
    $bn->{name} = 'badnode';
}

# 5) Write local_data/badnode in the correct dumped format
_write_badnode_hashfile('badnode', \%final);

# 6) Counters
my $final_total = scalar keys %final;
my $removed = $before_mem - $final_total; $removed = 0 if $removed < 0;
my $added   = $final_total - $before_mem; $added   = 0 if $added   < 0;

push @out, "Rebuilt disk -> memory";
push @out, "Before rebuild: $before_mem";
push @out, "Loaded from disk: $loaded_from_disk";
push @out, "Removed: $removed";
push @out, "Added: $added";
push @out, "Final total: $final_total";

return (1, @out);
