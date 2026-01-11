#
# baddx.pl - Merge baddx entries in memory (DXProt::baddx, a DXHash)
#            with baddx.new on disk (downloaded from repo),
#            then write local_data/baddx in DXHash dumped format (bless({..}, 'DXHash')).
#
# baddx (memory): DXHash storing CALLSIGN => epoch_timestamp
# baddx.new (disk): plain text file, one callsign per line (comments with # allowed)
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

sub _baddx_obj {
    # DXProt.pm defines $baddx in package DXProt
    no strict 'refs';
    return $DXProt::baddx;
}

sub _is_key {
    my ($k) = @_;
    return 0 unless defined $k && length $k;
    return 0 if $k eq 'name';
    return 1;
}

sub _mem_hash {
    my ($hx) = @_;
    my %h;

    return %h unless $hx && ref($hx) eq 'DXHash';

    for my $k (keys %{$hx}) {
        next unless _is_key($k);
        my $v = $hx->{$k};
        next unless defined $v && $v =~ /^\d+$/;   # epoch
        $h{$k} = $v;
    }
    return %h;
}

sub _read_new_list {
    my $fn = localdata("baddx.new");
    my @items;
    return @items unless -e $fn;

    open(my $fh, '<', $fn) or return @items;
    while (my $l = <$fh>) {
        chomp $l;
        $l =~ s/\r$//;
        $l =~ s/^\s+|\s+$//g;
        next if $l eq '';
        next if $l =~ /^\s*\#/;

        # Keep original shape (case) is not important; DXSpider typically uses upper
        $l = uc($l);

        # Allow typical callsign chars plus '/' and '-' (e.g. EA4HA/CKING, LU/EA7IXM)
        next unless $l =~ /^[A-Z0-9\/\-]+$/;

        push @items, $l;
    }
    close $fh;

    return @items;
}

sub _write_hashfile {
    my ($name, $href) = @_;
    my $fn = localdata($name);

    open(my $fh, '>', $fn) or return 0;

    print $fh "bless( {\n";

    # Sort keys; keep "name" last
    for my $k (sort keys %{$href}) {
        my $v = $href->{$k};
        next unless defined $v && $v =~ /^\d+$/;

        # Quote keys if needed (contain '/' or '-' etc.)
        my $key_out = ($k =~ /^[A-Z0-9]+$/) ? $k : "'" . $k . "'";
        print $fh "  $key_out => $v,\n";
    }

    print $fh "  name => '$name',\n";
    print $fh "}, 'DXHash' )\n";

    close $fh;
    return 1;
}

# ---------------- main ----------------

my $bx = _baddx_obj();

# 1) Snapshot memory BEFORE merge
my %mem = _mem_hash($bx);
my $before_mem = scalar keys %mem;

# 2) Read baddx.new from disk (repo-downloaded)
my @disk_items = _read_new_list();
my $loaded_from_disk = scalar @disk_items;

# 3) Union: start from memory (preserve timestamps), add disk items (new ones get "now")
my %final = %mem;
my $now = time;

for my $c (@disk_items) {
    next unless defined $c && length $c;
    $final{$c} = $now unless exists $final{$c};
}

# 4) Update in-memory DXProt::baddx too
if ($bx && ref($bx) eq 'DXHash') {
    for my $k (keys %final) {
        $bx->{$k} = $final{$k} unless exists $bx->{$k};
    }
    $bx->{name} = 'baddx';
}

# 5) Write local_data/baddx in the correct dumped format
_write_hashfile('baddx', \%final);

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
