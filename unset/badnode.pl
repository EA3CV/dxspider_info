#
# unset/badnode.pl - Remove a badnode entry
#
# Behaviour:
#   - If local_data/badnode.local does not exist, create it and
#     populate it from the current in-memory DXProt::badnode list.
#   - Remove the callsign passed to the command from badnode.local
#     if present (comments and empty lines are preserved).
#   - Always perform the standard DXSpider badnode->unset() action.
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

    for my $k (keys %{$bn}) {
        next unless _is_key($k);
        push @items, uc($k);
    }

    my %seen;
    @items = grep { !$seen{$_}++ } @items;

    return sort @items;
}

sub _ensure_badnode_local_from_mem {
    my $fn = localdata("badnode.local");
    return unless defined $fn && length $fn;

    return if -e $fn;

    my @items = _mem_badnode_items();

    if (open(my $fh, '>', $fn)) {
        for my $c (@items) {
            next unless defined $c && length $c;
            print $fh "$c\n";
        }
        close $fh;
    }
}

sub _remove_call {
    my ($fn, $call) = @_;
    return unless -e $fn;

    my @keep;
    my $changed = 0;

    if (open(my $rfh, '<', $fn)) {
        while (my $l = <$rfh>) {
            my $orig = $l;

            chomp $l; $l =~ s/\r$//;
            my $t = $l;
            $t =~ s/^\s+|\s+$//g;

            # conservar comentarios / vacías tal cual
            if ($t eq '' || $t =~ /^\s*\#/) {
                push @keep, $orig;
                next;
            }

            my $u = uc($t);
            if ($u eq $call) {
                $changed = 1;
                next;
            }

            push @keep, $orig;
        }
        close $rfh;
    }

    if ($changed) {
        if (open(my $wfh, '>', $fn)) {
            print $wfh @keep;
            close $wfh;
        }
    }
}

# ---------------- local side-effect ----------------

my ($call) = split(/\s+/, $line // '');
$call = '' unless defined $call;
$call =~ s/^\s+|\s+$//g;
$call = uc($call);

if ($call ne '' && $call =~ /^[A-Z0-9\/\-]+$/) {
    # si no existe, lo creamos y volcamos memoria la primera vez
    _ensure_badnode_local_from_mem();

    my $fn = localdata("badnode.local");
    if (defined $fn && length $fn && -e $fn) {
        _remove_call($fn, $call);
    }
}

# ---------------- existing behavior ----------------
return $DXProt::badnode->unset(8, $self->msg('e12'), $self, $line);
