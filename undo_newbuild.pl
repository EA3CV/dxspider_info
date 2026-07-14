#!/usr/bin/perl

#
# Restore the DXSpider installation from a backup created by check_build.pl.
#
# This command is the rollback companion for check_build.pl v1.33 or later.
# It restores the complete installation snapshot that existed immediately
# before the update.
#
# Usage:
#
#   undo_newbuild
#   undo_newbuild spider.20260714.141644.tar.gz
#   undo_newbuild /home/sysop/spider.backup/spider.20260714.141644.tar.gz
#
# The script first resolves the real filesystem path of $main::root.
# This works whether the configured root is a real directory or a
# symbolic link.
#
# Example:
#
#   /spider -> /home/sysop/spider
#   backup  -> /home/sysop/spider.backup
#
# Without an explicit archive, the newest valid backup is selected from:
#
#   1. A directory beside the resolved DXSpider installation path.
#   2. The process user's home directory, obtained from getpwuid($<):
#
#          <process-user-home>/spider.backup
#
# Root privileges and a fixed /home/sysop path are not assumed.
#
# IMPORTANT:
#
#   - The archive must have been created by check_build.pl.
#   - The archive is validated before any production file is modified.
#   - The archive is extracted to a temporary staging directory first.
#   - Runtime data excluded by check_build.pl is preserved:
#
#       local_data/debug
#       local_data/log
#       local_data/spots
#       local_data/wwv
#       local_data/wcy
#
#   - All other files are restored to their state at backup time.
#   - Files created after the backup, outside the excluded runtime paths,
#     are removed by rsync --delete.
#   - Every step is written to the DXSpider logs under the category:
#
#       undo_newbuild
#
# Required system packages:
#
#   apt update
#   apt install git rsync tar
#
# No additional CPAN modules are required.
#
# Kin EA3CV, ea3cv@cronux.net
#
# 20260714 v1.3
#

use 5.10.1;
use DXDebug;
use DXLog ();
use strict;
use warnings;
use Fcntl qw(:flock);
use File::Path qw(remove_tree);
use Cwd qw(realpath);

my ($self, $line) = @_;

return 1 unless $self->{priv} >= 9;

my @args = grep { length $_ } split /\s+/, ($line // '');
my $requested_archive = $args[0];

my @out;

my $script_build = '20260714-v1.3';
my $lock_file    = '/tmp/dxspider-undo-newbuild.lock';

report(\@out, "SCRIPT BUILD : $script_build");
report(\@out, '------------------------------------------------------------');
report(\@out, 'DXSpider Build Rollback v1.3');
report(\@out, '------------------------------------------------------------');
report(\@out, '');
report(\@out, 'Starting rollback validation ...');

open my $lock_fh, '>>', $lock_file
    or return failure(\@out, "Cannot open lock file '$lock_file': $!");

unless (flock($lock_fh, LOCK_EX | LOCK_NB)) {
    return failure(
        \@out,
        'Another undo_newbuild process is already running.'
    );
}

unless (defined $main::root && length $main::root && -d $main::root) {
    return failure(
        \@out,
        'DXSpider root directory is not defined or does not exist.'
    );
}

my $configured_root = $main::root;
my $root = realpath($configured_root);

unless (defined $root && -d $root) {
    return failure(
        \@out,
        "Cannot resolve the real DXSpider installation path from " .
        "'$configured_root'."
    );
}

report(\@out, "Configured root : $configured_root");
report(\@out, "Resolved root   : $root");
report(\@out, 'Selecting backup archive ...');

my ($archive, $backup_dir, $archive_error) =
    select_backup_archive($root, $requested_archive);

unless (defined $archive && defined $backup_dir) {
    return failure(\@out, $archive_error);
}

report(\@out, "Backup path   : $backup_dir");

unless (-f $archive && -r $archive && -s $archive) {
    return failure(
        \@out,
        "Backup archive '$archive' does not exist, is unreadable or is empty."
    );
}

report(\@out, "  Selected: $archive");
report(\@out, 'Validating archive structure ...');

my ($tar_list, $tar_list_status) =
    capture_command('tar', '-tzf', $archive);

unless ($tar_list_status == 0 && defined $tar_list && length $tar_list) {
    return failure(
        \@out,
        "Cannot read archive '$archive' " .
        "(tar status $tar_list_status)."
    );
}

my @members = grep { length $_ } split /\n/, $tar_list;

unless (@members) {
    return failure(
        \@out,
        "Backup archive '$archive' contains no files."
    );
}

my %top_level;

for my $member (@members) {
    $member =~ s{\A\./}{};

    if ($member =~ m{\A/}) {
        return failure(
            \@out,
            "Unsafe absolute path found in archive: '$member'."
        );
    }

    my @parts = grep { length $_ && $_ ne '.' } split m{/+}, $member;

    if (grep { $_ eq '..' } @parts) {
        return failure(
            \@out,
            "Unsafe parent-directory path found in archive: '$member'."
        );
    }

    next unless @parts;
    $top_level{$parts[0]} = 1;
}

my @top_dirs = sort keys %top_level;

unless (@top_dirs == 1 &&
        $top_dirs[0] =~ /\A\d{8}\.\d{6}\z/) {
    return failure(
        \@out,
        'The archive must contain exactly one timestamped top-level ' .
        'directory created by check_build.pl.'
    );
}

my $snapshot_name = $top_dirs[0];
my $staging_dir   =
    "$backup_dir/.undo_newbuild.$$." . time();
my $snapshot_root = "$staging_dir/$snapshot_name";

report(\@out, "  OK  Snapshot directory: $snapshot_name");
report(\@out, "Creating staging directory: $staging_dir");

unless (mkdir $staging_dir, 0700) {
    return failure(
        \@out,
        "Cannot create staging directory '$staging_dir': $!"
    );
}

report(\@out, 'Extracting backup to staging ...');

my $extract_status = system(
    'tar',
    '-C', $staging_dir,
    '-xzf', $archive
);

unless (command_succeeded($extract_status)) {
    cleanup_staging($staging_dir);

    return failure(
        \@out,
        'Archive extraction failed ' .
        '(tar exit ' . command_exit_code($extract_status) . ').'
    );
}

unless (-d $snapshot_root) {
    cleanup_staging($staging_dir);

    return failure(
        \@out,
        "Expected snapshot directory '$snapshot_root' was not extracted."
    );
}

unless (-d "$snapshot_root/.git") {
    cleanup_staging($staging_dir);

    return failure(
        \@out,
        "The snapshot does not contain a Git repository: " .
        "'$snapshot_root/.git' is missing."
    );
}

report(\@out, '  OK  Archive extracted.');
report(\@out, 'Validating snapshot Git repository ...');

my ($snapshot_work_tree, $snapshot_work_tree_status) =
    capture_git_at(
        $snapshot_root,
        'rev-parse',
        '--is-inside-work-tree'
    );

unless ($snapshot_work_tree_status == 0 &&
        defined $snapshot_work_tree &&
        $snapshot_work_tree eq 'true') {
    cleanup_staging($staging_dir);

    return failure(
        \@out,
        'The extracted snapshot is not a valid Git working tree.'
    );
}

my ($snapshot_commit, $snapshot_commit_status) =
    capture_git_at(
        $snapshot_root,
        'rev-parse',
        '--verify',
        'HEAD^{commit}'
    );

unless ($snapshot_commit_status == 0 &&
        defined $snapshot_commit &&
        $snapshot_commit =~ /\A[0-9a-f]{40,64}\z/) {
    cleanup_staging($staging_dir);

    return failure(
        \@out,
        'The extracted snapshot HEAD does not resolve to a valid commit.'
    );
}

my ($snapshot_branch, $snapshot_branch_status) =
    capture_git_at(
        $snapshot_root,
        'symbolic-ref',
        '--quiet',
        '--short',
        'HEAD'
    );

$snapshot_branch = '(detached HEAD)'
    if $snapshot_branch_status != 0 ||
       !defined $snapshot_branch ||
       !length $snapshot_branch;

report(\@out, "  Snapshot branch: $snapshot_branch");
report(\@out, "  Snapshot commit: $snapshot_commit");

my ($current_commit, $current_commit_status) =
    capture_git_at(
        $root,
        'rev-parse',
        '--verify',
        'HEAD^{commit}'
    );

$current_commit = '(undefined)'
    if $current_commit_status != 0 ||
       !defined $current_commit ||
       !length $current_commit;

my ($current_branch, $current_branch_status) =
    capture_git_at(
        $root,
        'symbolic-ref',
        '--quiet',
        '--short',
        'HEAD'
    );

$current_branch = '(detached HEAD)'
    if $current_branch_status != 0 ||
       !defined $current_branch ||
       !length $current_branch;

report(\@out, "Current branch : $current_branch");
report(\@out, "Current commit : $current_commit");
report(\@out, '');
report(\@out, 'Rollback will now restore the selected snapshot.');
report(\@out, 'Runtime data directories will be preserved.');

my $node_call =
    defined $main::mycall && length $main::mycall
        ? $main::mycall
        : 'DXSpider';

is_tg("*$node_call*   Rollback Starts");

my @exclude = (
    '--exclude=local_data/debug',
    '--exclude=local_data/log',
    '--exclude=local_data/spots',
    '--exclude=local_data/wwv',
    '--exclude=local_data/wcy'
);

report(\@out, 'Restoring snapshot with rsync ...');

my $rsync_status = system(
    'rsync',
    '-a',
    '--delete',
    @exclude,
    "$snapshot_root/",
    "$root/"
);

unless (command_succeeded($rsync_status)) {
    cleanup_staging($staging_dir);

    return failure(
        \@out,
        'Rollback rsync failed ' .
        '(exit ' . command_exit_code($rsync_status) . '). ' .
        'The installation may be partially restored and must be checked ' .
        'manually before restarting.'
    );
}

report(\@out, '  OK  Snapshot files restored.');
report(\@out, 'Verifying restored Git state ...');

my ($restored_commit, $restored_commit_status) =
    capture_git_at(
        $root,
        'rev-parse',
        '--verify',
        'HEAD^{commit}'
    );

unless ($restored_commit_status == 0 &&
        defined $restored_commit &&
        $restored_commit eq $snapshot_commit) {
    my $shown_commit =
        defined $restored_commit && length $restored_commit
            ? $restored_commit
            : '(undefined)';

    cleanup_staging($staging_dir);

    return failure(
        \@out,
        "Restored commit verification failed: expected " .
        "'$snapshot_commit', found '$shown_commit' " .
        "(git status $restored_commit_status)."
    );
}

my ($restored_branch, $restored_branch_status) =
    capture_git_at(
        $root,
        'symbolic-ref',
        '--quiet',
        '--short',
        'HEAD'
    );

$restored_branch = '(detached HEAD)'
    if $restored_branch_status != 0 ||
       !defined $restored_branch ||
       !length $restored_branch;

unless ($restored_branch eq $snapshot_branch) {
    cleanup_staging($staging_dir);

    return failure(
        \@out,
        "Restored branch verification failed: expected " .
        "'$snapshot_branch', found '$restored_branch'."
    );
}

report(\@out, "  OK  Restored branch: $restored_branch");
report(\@out, "  OK  Restored commit: $restored_commit");

unless (cleanup_staging($staging_dir)) {
    report(
        \@out,
        "WARNING: Could not completely remove staging directory " .
        "'$staging_dir'."
    );
}
else {
    report(\@out, '  OK  Staging directory removed.');
}

report(\@out, '');
report(\@out, 'Rollback completed successfully.');
report(\@out, "Restored archive: $archive");
report(\@out, 'DXSpider shutdown/restart has been requested.');
report(\@out, 'Finished successfully.');

is_tg("*$node_call*   Last build rollback completed");

DXLog::flushall();
DXCron::run_cmd('shut');

return 1;


sub backup_directories
{
    my ($root) = @_;

    my @dirs = ("$root.backup");
    my $home = (getpwuid($<))[7];

    if (defined $home && length $home && -d $home) {
        my $home_dir = "$home/spider.backup";
        push @dirs, $home_dir unless grep { $_ eq $home_dir } @dirs;
    }

    return @dirs;
}


sub select_backup_archive
{
    my ($root, $requested) = @_;

    if (defined $requested && length $requested) {
        if ($requested =~ m{\A/}) {
            my $dir = $requested;
            $dir =~ s{/[^/]+\z}{};

            return (
                undef,
                undef,
                "Explicit archive '$requested' is not a readable non-empty file."
            ) unless -f $requested && -r $requested && -s $requested;

            return ($requested, $dir, undef);
        }

        unless ($requested =~ /\Aspider\.\d{8}\.\d{6}\.tar\.gz\z/) {
            return (
                undef,
                undef,
                "Invalid archive name '$requested'."
            );
        }

        for my $dir (backup_directories($root)) {
            my $candidate = "$dir/$requested";

            return ($candidate, $dir, undef)
                if -f $candidate && -r $candidate && -s $candidate;
        }

        return (
            undef,
            undef,
            "Archive '$requested' was not found in any supported backup directory."
        );
    }

    my @archives;

    for my $dir (backup_directories($root)) {
        next unless -d $dir && -r $dir && -x $dir;

        push @archives,
            grep { -f $_ && -r $_ && -s $_ }
            glob("$dir/spider.*.tar.gz");
    }

    unless (@archives) {
        return (
            undef,
            undef,
            'No readable backup archives were found beside the DXSpider ' .
            'installation or in the process user home directory.'
        );
    }

    @archives = sort {
        (stat($a))[9] <=> (stat($b))[9] || $a cmp $b
    } @archives;

    my $archive = $archives[-1];
    my $dir = $archive;
    $dir =~ s{/[^/]+\z}{};

    return ($archive, $dir, undef);
}


sub report
{
    my ($out, $message) = @_;

    $message = '' unless defined $message;

    push @$out, $message
        if $out && ref($out) eq 'ARRAY';

    DXLog::LogDbg('undo_newbuild', $message);

    return 1;
}


sub failure
{
    my ($out, $message) = @_;

    report($out, '');
    report($out, 'ERROR');
    report($out, $message);
    report($out, 'Rollback cancelled.');
    report($out, 'DXSpider has not been intentionally shut down.');
    report($out, 'Finished with errors.');

    DXLog::flushall();

    return 1;
}


sub capture_git_at
{
    my ($directory, @args) = @_;

    return capture_command(
        'git',
        '-C', $directory,
        @args
    );
}


sub capture_command
{
    my @command = @_;

    open my $fh, '-|', @command
        or return ('', 255);

    local $/;
    my $output = <$fh>;
    $output = '' unless defined $output;

    my $closed = close $fh;
    my $status = $?;

    $output =~ s/\s+\z//;

    return ($output, 255)
        unless $closed || command_succeeded($status);

    return (
        $output,
        command_succeeded($status)
            ? 0
            : command_exit_code($status)
    );
}


sub command_succeeded
{
    my ($status) = @_;

    return 0 unless defined $status;
    return 0 if $status == -1;
    return 0 if $status & 127;

    return (($status >> 8) == 0) ? 1 : 0;
}


sub command_exit_code
{
    my ($status) = @_;

    return 'unknown' unless defined $status;
    return 'failed to execute' if $status == -1;

    if ($status & 127) {
        return 'terminated by signal ' . ($status & 127);
    }

    return $status >> 8;
}


sub cleanup_staging
{
    my ($directory) = @_;

    return 1 unless defined $directory && -e $directory;

    my $errors = [];

    remove_tree(
        $directory,
        {
            safe  => 1,
            error => $errors
        }
    );

    return @$errors ? 0 : 1;
}


sub is_tg
{
    my ($message) = @_;

    return unless defined &Local::telegram;

    my $result;

    eval {
        $result = Local::telegram($message);
        1;
    };

    return $result;
}
