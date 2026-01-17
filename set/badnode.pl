#
# set/badnode.pl - Add a badnode entry
#
# Behaviour:
#   - If local_data/badnode.local does not exist, create it and
#     populate it from the current in-memory DXProt::badnode list.
#   - Append the callsign passed to the command to badnode.local
#     (one per line, uppercase, no duplicates).
#   - Always perform the standard DXSpider badnode->set() action.
#
# Copyright (c) 1998 - Dirk Koopman G1TLH
#
# Modified by Kin EA3CV <ea3cv@cronux.net>
#
# 20260117 v1.0
#

use strict;
use warnings;

use DXUtil;   # localdata()

my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd;

# are we permitted?
return (1, $self->msg('e5')) if $self->priv < 6;

# ---------------- helpers ----------------

sub _is_key {
    my ($k) = @_;
    return 0 unless defined $k && length $k;
    return 0 if $k eq 'name';
    return 1;
}

sub _badnode_obj {
    no strict 'refs';
    return $DXProt::badnode;
}

sub _mem_badnode_items {
    my $bn = _badnode_obj();
    my @items;

    return @items unless $bn && ref($bn);

    # DXHash normalmente se comporta como hashref
    for my $k (keys %{$bn}) {
        next unless _is_key($k);
        push @items, uc($k);
    }

    # uniq
    my %seen;
    @items = grep { !$seen{$_}++ } @items;

    return sort @items;
}

sub _ensure_badnode_local_from_mem {
    my $fn = localdata("badnode.local");
    return unless defined $fn && length $fn;

    return if -e $fn;  # ya existe

    my @items = _mem_badnode_items();

    if (open(my $fh, '>', $fn)) {
        for my $c (@items) {
            next unless defined $c && length $c;
            print $fh "$c\n";
        }
        close $fh;
    }
    # si falla, no abortamos; el comando seguirá
}

sub _append_if_missing {
    my ($fn, $call) = @_;
    return unless -e $fn;

    my $exists = 0;
    if (open(my $rfh, '<', $fn)) {
        while (my $l = <$rfh>) {
            chomp $l; $l =~ s/\r$//;
            $l =~ s/^\s+|\s+$//g;
            next if $l eq '' || $l =~ /^\s*\#/;
            $l = uc($l);
            if ($l eq $call) { $exists = 1; last; }
        }
        close $rfh;
    }

    if (!$exists) {
        if (open(my $afh, '>>', $fn)) {
            print $afh "$call\n";
            close $afh;
        }
    }
}

# ---------------- local side-effect ----------------

my ($call) = split(/\s+/, $line // '');
$call = '' unless defined $call;
$call =~ s/^\s+|\s+$//g;
$call = uc($call);

if ($call ne '' && $call =~ /^[A-Z0-9\/\-]+$/) {
    _ensure_badnode_local_from_mem();

    my $fn = localdata("badnode.local");
    if (defined $fn && length $fn && -e $fn) {
        _append_if_missing($fn, $call);
    }
}

# ---------------- existing behavior ----------------
return $DXProt::badnode->set(8, $self->msg('e12'), $self, $line);
