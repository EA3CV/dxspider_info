#
# badspotter.pl - Merge badspotter entries in memory (DXProt::badspotter, a DXHash)
#                 with badspotter.new on disk (downloaded from repo),
#                 then write local_data/badspotter in DXHash dumped format (bless({..}, 'DXHash')).
#
# badspotter (memory): DXHash storing SPOTTERCALL => epoch_timestamp
# badspotter.new (disk): plain text file, one spotter callsign per line (comments with # allowed)
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

sub _badspotter_obj {
    # DXProt.pm defines $badspotter in package DXProt
    no strict 'refs';
    return $DXProt::badspotter;
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
    my $fn = localdata("badspotter.new");
    my @items;
    return @items unless -e $fn;

    open(my $fh, '<', $fn) or return @items;
    while (my $l = <$fh>) {
        chomp $l;
        $l =~ s/\r$//;
        $l =~ s/^\s+|\s+$//g;
        next if $l eq '';
        next if $l =~ /^\s*\#/;

        $l = uc($l);

        # Spotter callsigns can contain '-' (e.g. VE7CC-1). Usually no '/', but
        # allowing '/' doesn't hurt for portability; tighten if you prefer.
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

my $bs = _badspotter_obj();

# 1) Snapshot memory BEFORE merge
my %mem = _mem_hash($bs);
my $before_mem = scalar keys %mem;

# 2) Read badspotter.new from disk (repo-downloaded)
my @disk_items = _read_new_list();
my $loaded_from_disk = scalar @disk_items;

# 3) Union: start from memory (preserve timestamps), add disk items (new ones get "now")
my %final = %mem;
my $now = time;

for my $c (@disk_items) {
    next unless defined $c && length $c;
    $final{$c} = $now unless exists $final{$c};
}

# 4) Update in-memory DXProt::badspotter too
if ($bs && ref($bs) eq 'DXHash') {
    for my $k (keys %final) {
        $bs->{$k} = $final{$k} unless exists $bs->{$k};
    }
    $bs->{name} = 'badspotter';
}

# 5) Write local_data/badspotter in the correct dumped format
_write_hashfile('badspotter', \%final);

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
