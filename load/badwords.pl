#
# badwords.pl - Rebuild badwords in-memory ONLY from disk sources:
#               badword.new (via BadWords::load) + any badword.* files,
#               then write back updated badword.new (no duplicates).
#
# Usage:
#   load/badwords
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
# 20260115 v1.3
#

use strict;
use warnings;

use BadWords;

my ($self, $line) = @_;
my @out;

return (1, $self->msg('e5')) if $self->priv < 9;

# Count current in-memory list BEFORE rebuild
my $before_mem = scalar BadWords::list_regex(0);   # canonical words only

# Load base list from filesystem (badword.new if present; otherwise legacy+migration)
my @load_err = BadWords::load();
if (@load_err) {
    push @out, "Rebuilt disk -> memory";
    push @out, "Before rebuild: $before_mem";
    push @out, "Loaded from disk: 0";
    push @out, "Removed: 0";
    push @out, "Added: 0";
    push @out, "Final total: $before_mem";
    push @out, @load_err;
    return (1, @out);
}

# ---------------- load extra badword.* files ----------------
# We add words found in /spider/local_data/badword.<suffix> (suffix = \w+),
# skipping badword.new (already handled by BadWords::load()) and badword.run
# (often command-style content). We also ignore command-like lines if present.
my @extra_words;

eval {
    my $dir;
    opendir($dir, $main::local_data) or die "opendir($main::local_data): $!";
    while (my $fn = readdir $dir) {
        next unless my ($suffix) = $fn =~ /^badword\.(\w+)$/;

        next if $suffix eq 'new';   # already loaded
        next if $suffix eq 'run';   # typically contains commands, not words

        my $path = "$main::local_data/$fn";
        next unless -f $path;

        open(my $fh, '<', $path) or next;
        while (my $l = <$fh>) {
            chomp($l);
            $l =~ s/\r$//;
            $l =~ s/#.*$//;          # strip comments
            $l =~ s/^\s+|\s+$//g;    # trim
            next if $l eq '';

            # Skip command-like lines (just in case)
            next if $l =~ m{^(?:set|unset)\s*/}i;
            next if $l =~ m{^(?:set|unset)/}i;

            push @extra_words, $l;
        }
        close $fh;
    }
    closedir $dir;
};

# Add extra words in chunks (avoid very long argument strings)
if (@extra_words) {
    my @chunk;
    for my $w (@extra_words) {
        push @chunk, $w;
        if (@chunk >= 200) {
            BadWords::add_regex(join(' ', @chunk));
            @chunk = ();
        }
    }
    BadWords::add_regex(join(' ', @chunk)) if @chunk;
}

# Rebuild regex after loading all disk sources
BadWords::generate_regex();

my $final_total = scalar BadWords::list_regex(0);

# Compute removed/added relative to previous in-memory state
my $removed = $before_mem - $final_total; $removed = 0 if $removed < 0;
my $added   = $final_total - $before_mem; $added   = 0 if $added   < 0;

# Persist canonical output (typically badword.new)
BadWords::put();

# Output
push @out, "Rebuilt disk -> memory";
push @out, "Before rebuild: $before_mem";
push @out, "Loaded from disk: $final_total";
push @out, "Removed: $removed";
push @out, "Added: $added";
push @out, "Final total: $final_total";

return (1, @out);
