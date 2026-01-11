#
# badwords.pl - Merge current in-memory badwords + badword.new on disk,
#               then write back updated badword.new (no duplicates)
#
# Usage:
#   load/badwords
#
# Output (always):
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

use BadWords;

my ($self, $line) = @_;
my @out;

return (1, $self->msg('e5')) if $self->priv < 9;

# Snapshot current in-memory list BEFORE load() resets it
my @mem_words  = BadWords::list_regex(0);   # canonical words only
my $before_mem = scalar @mem_words;

# Load from filesystem (badword.new if present; otherwise legacy + migration)
my @load_err = BadWords::load();
if (@load_err) {
    # Minimal, but still returns something meaningful
    push @out, "Merged memory+disk";
    push @out, "Before merge: $before_mem";
    push @out, "Loaded from disk: 0";
    push @out, "New additions: 0";
    push @out, "Final total: $before_mem";
    push @out, @load_err;
    return (1, @out);
}

# Count what disk provided (now in memory after load)
my $loaded_from_disk = scalar BadWords::list_regex(0);

# Merge previous memory snapshot back in (union behavior)
if (@mem_words) {
    BadWords::add_regex(join(' ', @mem_words));
}

# Rebuild regex and compute final totals
BadWords::generate_regex();
my $final_total = scalar BadWords::list_regex(0);

# Net increase relative to what was in memory before
my $new_additions = $final_total - $before_mem;
$new_additions = 0 if $new_additions < 0;

# Persist (do not print any write status/errors)
BadWords::put();

# Output in the exact order requested
push @out, "Merged memory+disk";
push @out, "Before merge: $before_mem";
push @out, "Loaded from disk: $loaded_from_disk";
push @out, "New additions: $new_additions";
push @out, "Final total: $final_total";

return (1, @out);
