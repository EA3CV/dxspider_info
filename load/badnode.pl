#
# badnode.pl - Merge badnode entries in memory with badnode.new (downloaded from repo),
#              then write local_data/badnode in DXHash dumped format (bless({..}, 'DXHash')).
#
# Output order:
#   Merged memory+disk
#   Before merge: <n>
#   Loaded from disk: <n>
#   New additions: <n>
#   Final total: <n>
#
# Privilege: priv >= 9
#
# Kin EA3CV <ea3cv@cronux.net>
#
# 20260111 v1.0
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

sub _read_badnode_new_list {
    my $fn = localdata("badnode.new");
    my @nodes;
    return @nodes unless -e $fn;

    open(my $fh, '<', $fn) or return @nodes;
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

sub _write_badnode_hashfile {
    my ($name, $href) = @_;
    my $fn = localdata("badnode");

    open(my $fh, '>', $fn) or return 0;

    print $fh "bless( {\n";

    # Sort keys, but keep "name" as the last field (as in your example)
    for my $k (sort keys %{$href}) {
        my $v = $href->{$k};
        next unless defined $v && $v =~ /^\d+$/;

        # Quote keys if needed (e.g., DB0ERF-5, 9M2PJU-1)
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

# 1) Snapshot memory BEFORE merge
my %mem = _mem_nodes_hash($bn);
my $before_mem = scalar keys %mem;

# 2) Read disk list (badnode.new from repo)
my @disk_nodes = _read_badnode_new_list();
my $loaded_from_disk = scalar @disk_nodes;

# 3) Build union: start from memory (keep original timestamps), add disk nodes (new ones get "now")
my %final = %mem;
my $now = time;

for my $n (@disk_nodes) {
    next unless defined $n && length $n;
    $final{$n} = $now unless exists $final{$n};
}

# 4) Update in-memory DXProt::badnode too (keep behaviour consistent)
if ($bn && ref($bn) eq 'DXHash') {
    for my $k (keys %final) {
        $bn->{$k} = $final{$k} unless exists $bn->{$k};
    }
    $bn->{name} = 'badnode';   # keep metadata consistent
}

# 5) Write local_data/badnode in the correct dumped format
_write_badnode_hashfile('badnode', \%final);

# 6) Counters
my $final_total = scalar keys %final;
my $new_additions = $final_total - $before_mem;
$new_additions = 0 if $new_additions < 0;

push @out, "Merged memory+disk";
push @out, "Before merge: $before_mem";
push @out, "Loaded from disk: $loaded_from_disk";
push @out, "New additions: $new_additions";
push @out, "Final total: $final_total";

return (1, @out);
