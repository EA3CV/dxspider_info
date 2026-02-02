#
# unset/badword.pl - Remove a badword entry persistently (dbfile or mysql)
#
# Behaviour:
#   - If suffix is provided:
#       * Ensure local_data/badword.<suffix> exists (optional)
#       * Remove word from badword.<suffix>
#   - If suffix is NOT provided:
#       * Remove word from ALL local_data/badword.* files found
#       * If none exist, fallback to badword.local
#   - If SQL backend is active:
#       * DELETE FROM badwords WHERE word = ?
#   - Always refresh runtime regex and persist if needed
#
# Copyright (c) 1998 - Dirk Koopman G1TLH
# Modified by Kin EA3CV
#
# 20260202 v1.0
#

use strict;
use warnings;

use DXUtil;   # localdata()

my ($self, $line) = @_;
return (1, $self->msg('e5')) if $self->remotecmd;
return (1, $self->msg('e5')) if $self->priv < 6;

# ---------------- helpers ----------------

sub _scan_badword_files {
    my $local_fn = localdata("badword.local");
    return () unless defined $local_fn && length $local_fn;

    (my $dir = $local_fn) =~ s{/[^/]+$}{};

    my @files;
    if (opendir my $dh, $dir) {
        @files = map { "$dir/$_" }
                 grep { /^badword\./ && -f "$dir/$_" }
                 readdir $dh;
        closedir $dh;
    }
    return @files;
}

sub _remove_word_from_file {
    my ($fn, $word) = @_;
    return 0 unless defined $fn && length $fn && -e $fn;

    my @keep;
    my $changed = 0;

    if (open(my $rfh, '<', $fn)) {
        while (my $orig = <$rfh>) {
            my $l = $orig;
            chomp $l; $l =~ s/\r$//;

            my $t = $l;
            $t =~ s/^\s+|\s+$//g;

            # conservar comentarios / vacías
            if ($t eq '' || $t =~ /^\s*\#/) {
                push @keep, $orig;
                next;
            }

            my ($tok) = split(/\s+/, $t, 2);
            $tok = '' unless defined $tok;

            my $u = uc($tok);
            if ($u eq $word) {
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

# intenta conseguir un DBH “ya abierto” por el cluster (para no reconectar aquí)
sub _get_dbh {
    my $dbh;

    # 1) Algunos setups lo guardan en un global
    no strict 'refs';
    $dbh = ${"main::dbh"} if defined ${"main::dbh"};

    # 2) Otros lo exponen vía algún módulo propio
    $dbh = $DXDb::dbh if !$dbh && defined $DXDb::dbh;        ## no critic
    $dbh = DXDb::dbh() if !$dbh && eval { DXDb->can('dbh') }; ## no critic

    return $dbh;
}

sub _sql_delete_badword {
    my ($word) = @_;
    my $dbh = _get_dbh();
    return (0, "SQL backend not available (no dbh)") unless $dbh;

    my $rows = 0;
    my $ok = eval {
        my $sth = $dbh->prepare('DELETE FROM badwords WHERE word = ?');
        $sth->execute($word);
        $rows = $sth->rows;
        1;
    };
    if (!$ok) {
        return (0, "SQL delete error: $@");
    }
    return ($rows > 0 ? 1 : 0, $rows > 0 ? "" : "word not present in SQL");
}

# ---------------- parse args ----------------

my @in = split /\s+/, ($line // '');

# Optional suffix: first token is suffix if there is at least one more token
my $suffix;
if (@in > 1 && defined $in[0] && $in[0] =~ /^[_\w\d]+$/) {
    $suffix = shift @in;
}

my $word = $in[0] // '';
$word =~ s/^\s+|\s+$//g;
$word = uc($word);

return (1, "Usage: unset/badword [suffix] WORD") unless $word ne '';
return (1, "Invalid word") unless $word =~ /^[A-Z0-9_\-\/]+$/;

# ---------------- do persistent removal ----------------

my @out;
my $changed_persistent = 0;

# A) Primero intenta SQL (si hay dbh)
my ($sql_changed, $sql_msg) = _sql_delete_badword($word);
if ($sql_changed) {
    $changed_persistent = 1;
    push @out, "BadWord $word removed from SQL";
} elsif ($sql_msg !~ /not available/i) {
    # hubo SQL, pero no borró fila (o no existía)
    push @out, "BadWord $word not in SQL" if $sql_msg =~ /not present/i;
    push @out, "BadWord $word SQL warning: $sql_msg" if $sql_msg =~ /error/i;
}

# B) Luego, backend dbfile: editar badword.* (esto convive bien aunque también uses SQL)
if (defined $suffix && length $suffix) {
    my $fn = localdata("badword.$suffix");
    if (defined $fn && -e $fn) {
        my $c = _remove_word_from_file($fn, $word);
        if ($c) {
            $changed_persistent = 1;
            push @out, "BadWord $word removed from file badword.$suffix";
        }
    }
} else {
    my @files = _scan_badword_files();
    if (@files) {
        my $any = 0;
        for my $fn (@files) {
            $any ||= _remove_word_from_file($fn, $word);
        }
        if ($any) {
            $changed_persistent = 1;
            push @out, "BadWord $word removed from files badword.*";
        }
    } else {
        # fallback a badword.local si no hay ninguno
        my $fn = localdata("badword.local");
        if (defined $fn && -e $fn) {
            my $c = _remove_word_from_file($fn, $word);
            if ($c) {
                $changed_persistent = 1;
                push @out, "BadWord $word removed from file badword.local";
            }
        }
    }
}

# ---------------- runtime / regex refresh ----------------

# Solo intentamos tocar runtime si existía en memoria o si tocamos persistencia
my @chk = eval { BadWords::check($word) };
my $touch_runtime = (@chk ? 1 : 0) || $changed_persistent;

if ($touch_runtime) {
    my $rt = eval { BadWords::del_regex($word) };
    # del_regex puede devolver lista/contador… lo dejamos “best effort”
    eval { BadWords::generate_regex(); };
    eval { BadWords::put(); };  # si put() persiste regex/estado en tu build
}

# ---------------- final message ----------------

if ($changed_persistent || $touch_runtime) {
    push @out, "BadWord $word removed";
} else {
    push @out, "BadWord $word not defined, ignored";
}

return (1, @out);
