#
# command_list.pl - Execute queued DXSpider commands from local_data/command.send
#                   and clear the file ONLY if all commands run successfully.
#
# Usage (from DXSpider console, sysop):
#   command_list
#
# File format: one command per line, e.g.:
#   set/badnode XX0ZZZ
#   unset/badnode YY9AAA
# Blank lines and lines starting with # are ignored.
#
# Safety:
# - Local only (no remotecmd)
# - Locks the file while processing
#
# Kin EA3CV <ea3cv@cronux.net>
# 20260114 v1.0
#

use strict;
use warnings;

use DXVars;
use DXUtil;

use Fcntl qw(:flock);

my ($self, $line) = @_;
my @out;

# Local only
return (1, $self->msg('e5')) if $self->remotecmd;

# Permission guard (recommended high, because this can run arbitrary commands)
return (1, $self->msg('e5')) if $self->priv < 9;

my $fn = "$main::local_data/command.send";

return (1, "command_list: file not found: $fn") unless -e $fn;

# Open read/write so we can truncate on success
open(my $fh, '+<', $fn) or return (1, "command_list: can't open $fn: $!");

# Lock to avoid races with downloads/edits
flock($fh, LOCK_EX) or do {
	close($fh);
	return (1, "command_list: can't lock $fn: $!");
};

# Read content
seek($fh, 0, 0);
my @raw = <$fh>;

my @cmds;
for my $l (@raw) {
	chomp $l;
	$l =~ s/\r$//;                # tolerate CRLF
	$l =~ s/^\s+|\s+$//g;         # trim
	next if $l eq '';
	next if $l =~ /^\s*#/;
	push @cmds, $l;
}

if (!@cmds) {
	close($fh);
	return (1, "command_list: no pending commands in $fn");
}

# Execute commands
my $failed = 0;

push @out, "command_list: executing " . scalar(@cmds) . " command(s) from $fn";

CMD: for my $cmd (@cmds) {
	push @out, "Executing: $cmd";

	my @res;
	my $ok = eval {
		@res = $self->run_cmd($cmd);
		1;
	};

	if (!$ok) {
		$failed = 1;
		my $err = $@ || 'unknown error';
		push @out, "ERROR: exception running '$cmd': $err";
		last CMD;
	}

	# Log command output (if any)
	for my $r (@res) {
		next unless defined $r;
		$r =~ s/\s+$//;
		next unless length $r;
		push @out, "  $r";
	}

	# Error detection (DXSpider often signals errors via text output)
	if (grep { defined($_) && $_ =~ /(unknown command|no such|permission denied|denied|error|failed|invalid)/i } @res) {
		$failed = 1;
		push @out, "ERROR: '$cmd' returned error-like output; aborting; file will NOT be cleared.";
		last CMD;
	}
}

if ($failed) {
	push @out, "command_list: NOT CLEARED. Fix the issue and rerun. File preserved: $fn";
	close($fh);
	return (1, @out);
}

# All good: clear the file
truncate($fh, 0) or do {
	push @out, "WARNING: commands executed, but could not truncate $fn: $!";
	close($fh);
	return (1, @out);
};

seek($fh, 0, 0);

push @out, "command_list: OK. Executed " . scalar(@cmds) . " command(s) and cleared $fn";
close($fh);

return (1, @out);
