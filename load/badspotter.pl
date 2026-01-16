#
# badspotter.pl - Rebuild badspotter entries in memory (DXProt::badspotter, a DXHash)
#                 from disk sources: badspotter.new + badspotter.local + any badspotter.* files in local_data,
#                 then write local_data/badspotter in DXHash dumped format.
#
# badspotter (memory): DXHash storing SPOTTERCALL => epoch_timestamp
# badspotter.new (disk): plain text file, one spotter callsign per line (comments with # allowed)
# badspotter.* (disk): additional plain text lists, same format (except badspotter.run is ignored)
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
# 20260116 v1.4
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

sub _read_list_file {
    my ($path) = @_;
    my @items;

    return @items unless defined $path && -e $path;

    open(my $fh, '<', $path) or return @items;
    while (my $l = <$fh>) {
        chomp $l;
        $l =~ s/\r$//;
        $l =~ s/^\s+|\s+$//g;
        next if $l eq '';
        next if $l =~ /^\s*\#/;

        $l = uc($l);

        # Spotter callsigns can contain '-' (e.g. VE7CC-1). Allow '/' too for portability.
        next unless $l =~ /^[A-Z0-9\/\-]+$/;

        push @items, $l;
    }
    close $fh;

    return @items;
}

sub _ensure_badspotter_local {
    my ($mem_href) = @_;

    my $fn = localdata("badspotter.local");
    return (0, 0) unless defined $fn && length $fn;

    # If it exists, do nothing
    return (1, 0) if -e $fn;

    # Create it from current in-memory snapshot
    my @items = sort keys %{ $mem_href || {} };

    if (open(my $fh, '>', $fn)) {
        for my $c (@items) {
            next unless defined $c && length $c;
            print $fh "$c\n";
        }
        close $fh;
        return (1, scalar(@items));
    }

    # Non-fatal: continue normal execution even if we can't create it
    return (0, 0);
}

sub _read_all_disk_items {
    my %seen;
    my @all;

    # 1) Base list: badspotter.new
    my $newfn = localdata("badspotter.new");
    for my $c (_read_list_file($newfn)) {
        next if $seen{$c}++;
        push @all, $c;
    }

    # 2) Extra lists: any badspotter.* in local_data (except .new, .run)
    #    NOTE: badspotter.local IS intentionally included here.
    eval {
        my $dir;
        opendir($dir, $main::local_data) or die "opendir($main::local_data): $!";
        while (my $fn = readdir $dir) {
            next unless my ($suffix) = $fn =~ /^badspotter\.(\w+)$/;

            next if $suffix eq 'new';
            next if $suffix eq 'run';

            my $path = "$main::local_data/$fn";
            next unless -f $path;

            for my $c (_read_list_file($path)) {
                next if $seen{$c}++;
                push @all, $c;
            }
        }
        closedir $dir;
    };

    return @all;
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

# 1) Snapshot memory BEFORE rebuild
my %mem = _mem_hash($bs);
my $before_mem = scalar keys %mem;

# 1b) Ensure badspotter.local exists (create it from memory snapshot if missing)
my ($ok_local, $created_n) = _ensure_badspotter_local(\%mem);
push @out, "Created badspotter.local from memory: $created_n" if $ok_local && $created_n;

# 2) Read disk sources (badspotter.new + badspotter.* including badspotter.local)
my @disk_items = _read_all_disk_items();
my $loaded_from_disk = scalar @disk_items;

# 3) Build final set ONLY from disk.
#    Preserve old timestamps for entries that still exist; new entries get "now".
my %final;
my $now = time;

for my $c (@disk_items) {
    next unless defined $c && length $c;
    $final{$c} = exists $mem{$c} ? $mem{$c} : $now;
}

# 4) Replace in-memory DXProt::badspotter content (purge removed entries)
if ($bs && ref($bs) eq 'DXHash') {
    for my $k (keys %{$bs}) {
        delete $bs->{$k} unless $k eq 'name';
    }
    for my $k (keys %final) {
        $bs->{$k} = $final{$k};
    }
    $bs->{name} = 'badspotter';
}

# 5) Write local_data/badspotter in the correct dumped format
_write_hashfile('badspotter', \%final);

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
