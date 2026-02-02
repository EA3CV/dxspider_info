#
# unset/badnode.pl - Remove a badnode entry
#
# Behaviour:
#   - If suffix is provided:
#       * Ensure local_data/badnode.<suffix> exists (populate from memory if missing)
#       * Remove the callsign from badnode.<suffix> (preserve comments/blank lines)
#   - If suffix is NOT provided:
#       * Remove the callsign from ALL local_data/badnode.* files found
#       * If none exist, ensure badnode.local exists (populate from memory) and try there
#   - Always perform the standard DXSpider badnode->unset() action.
#
# Copyright (c) 1998 - Dirk Koopman G1TLH
#
# Modified by Kin EA3CV <ea3cv@cronux.net>
#
# 20260117 v1.0
# 20260202 v1.1  scan all badnode.* when no suffix
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

sub _ensure_badnode_file_from_mem {
    my ($suffix) = @_;
    $suffix = 'local' unless defined $suffix && length $suffix;

    my $fn = localdata("badnode.$suffix");
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
    return 0 unless defined $fn && length $fn && -e $fn;

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

            # solo el primer token, por si hay "CALL comentario"
            my ($tok) = split(/\s+/, $t, 2);
            $tok = '' unless defined $tok;

            my $u = uc($tok);
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

    return $changed;
}

sub _scan_badnode_files {
    # returns list of full paths to local_data/badnode.*
    my $local_fn = localdata("badnode.local");
    return () unless defined $local_fn && length $local_fn;

    (my $dir = $local_fn) =~ s{/[^/]+$}{};

    my @files;
    if (opendir my $dh, $dir) {
        @files = map { "$dir/$_" }
                 grep { /^badnode\./ && -f "$dir/$_" }
                 readdir $dh;
        closedir $dh;
    }
    return @files;
}

# ---------------- parse args ----------------

my @in = split /\s+/, ($line // '');

# Optional suffix: treat first token as suffix if there is at least one more token
my $suffix;
if (@in > 1 && defined $in[0] && $in[0] =~ /^[_\w\d]+$/) {
    $suffix = shift @in;
}

my $call = $in[0] // '';
$call =~ s/^\s+|\s+$//g;
$call = uc($call);

# ---------------- local side-effect ----------------

if ($call ne '' && $call =~ /^[A-Z0-9\/\-]+$/) {

    if (defined $suffix && length $suffix) {
        # explicit suffix: ensure file exists and remove there
        _ensure_badnode_file_from_mem($suffix);
        my $fn = localdata("badnode.$suffix");
        _remove_call($fn, $call) if defined $fn && length $fn && -e $fn;

    } else {
        # no suffix: remove from ALL badnode.* files
        my @files = _scan_badnode_files();

        if (@files) {
            for my $fn (@files) {
                _remove_call($fn, $call);
            }
        } else {
            # fallback: historical behavior (ensure local exists, then remove there)
            _ensure_badnode_file_from_mem('local');
            my $fn = localdata("badnode.local");
            _remove_call($fn, $call) if defined $fn && length $fn && -e $fn;
        }
    }
}

# ---------------- existing behavior ----------------
return $DXProt::badnode->unset(8, $self->msg('e12'), $self, $line);
