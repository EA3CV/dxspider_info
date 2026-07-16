#!/usr/bin/perl

#
# Check whether a new DXSpider Mojo build is available.
#
# This command always verifies and synchronizes the installation against:
#
#   Primary repository: git://scm.dxcluster.org/spider
#   Backup repository:  git://scm.dxcluster.org/scm/spider
#   Branch:             mojo
#
# The current local branch and its configured upstream are ignored.
# If the repository was left on another branch, the command returns it
# to the local branch "mojo" and makes it match "origin/mojo".
#
# WARNING:
#   Synchronization discards local modifications to Git-tracked files.
#   Untracked files and directories are not deleted.
#
# Backup options:
#
#   check_build <Y/N> <num_backups> [backup_directory]
#
#   Y                  Create a backup before updating.
#   N                  Update without creating a backup.
#   num_backups        Maximum number of backup archives to retain.
#                      The default is 10.
#   backup_directory   Optional explicit backup directory.
#
# Backup directory selection:
#
#   The script first resolves the real filesystem path of $main::root.
#   This works whether the configured root is a real directory or a
#   symbolic link.
#
#   Examples:
#
#       /spider -> /home/sysop/spider
#       backup  -> /home/sysop/spider.backup
#
#       /home/sysop/spider
#       backup  -> /home/sysop/spider.backup
#
#   Selection order:
#
#   1. Use the explicit backup_directory argument, when supplied.
#   2. Otherwise, try a directory beside the resolved installation path.
#   3. If the process user cannot create or write that directory, use:
#
#          <process-user-home>/spider.backup
#
#      The process user home is obtained from getpwuid($<); it is not
#      assumed to be /home/sysop and root privileges are not required.
#
# Required system packages:
#
#   apt update
#   apt install git rsync
#
# No additional CPAN modules are required by this command.
# The Perl modules strict, warnings and Fcntl are included with Perl.
# DXDebug is supplied by DXSpider.
#
# Do not use cpanm to install rsync. rsync is an operating-system command,
# not a Perl module.
#
# Suggested DXSpider crontab entry:
#
#   0 4 * * * run_cmd('check_build <Y/N> <num_backups> [backup_directory]')
#
# Example: create a backup and retain the 10 newest backup archives:
#
#   0 4 * * * run_cmd('check_build Y 10')
#
# Initial DXSpider Mojo clone:
#
#   git clone --branch mojo --single-branch \
#       git://scm.dxcluster.org/spider /spider
#
# Emergency backup repository:
#
#   If the primary DXSpider Git repository is temporarily unavailable,
#   use the backup mirror:
#
#   git clone --branch mojo --single-branch \
#       https://github.com/EA3CV/dxspider.git /spider
#
#   The GitHub repository is a backup mirror of the Mojo branch and should
#   only be used while the primary repository is unavailable.
#
# Deprecated repository URL - do not use:
#
#   git://scm.dxcluster.org/scm/spider
#
# To keep check_build.pl updated automatically, add these entries to the
# DXSpider crontab. Thanks to Keith G6NHU for the original idea:
#
#   30 0 * * * spawn('wget -q -O /spider/local_cmd/check_build.pl https://raw.githubusercontent.com/EA3CV/dxspider_info/main/check_build.pl && chmod +x /spider/local_cmd/check_build.pl')
#   32 0 * * * run_cmd('load/cmd')
#
# Kin EA3CV, ea3cv@cronux.net
#
# 20260716 v1.28
#

use DXDebug;
use DXLog ();
use strict;
use warnings;
use Fcntl qw(:flock);
use Cwd qw(realpath);

my ($self, $line) = @_;

return 1 unless $self->{priv} >= 9;

my @args = grep { length $_ } split /\s+/, ($line // '');

my $backup_requested =
    defined $args[0] && $args[0] =~ /\AY\z/i ? 1 : 0;

my $max_copies = 10;

if (defined $args[1] && $args[1] =~ /\A\d+\z/ && $args[1] > 0) {
    $max_copies = int($args[1]);
}

my $requested_backup_dir =
    defined $args[2] && length $args[2]
        ? $args[2]
        : undef;

my @out;

my $git_remote_name = 'origin';
my $git_primary_url = 'git://scm.dxcluster.org/spider';
my $git_backup_url  = 'git://scm.dxcluster.org/scm/spider';
my $git_selected_url;
my $git_branch      = 'mojo';
my $remote_ref      = 'refs/remotes/origin/mojo';
my $lock_file       = '/tmp/dxspider-check-build.lock';

report($self, \@out, 'SCRIPT BUILD : 20260715-v1.28');

report($self, \@out, '------------------------------------------------------------');
report($self, \@out, 'DXSpider Build Checker v1.28');
report($self, \@out, "Primary repo : $git_primary_url");
report($self, \@out, "Backup repo  : $git_backup_url");
report($self, \@out, "Branch       : $git_branch");
report($self, \@out, "Root       : " . (defined $main::root ? $main::root : '(undefined)'));
report($self, \@out, "Backup     : " . ($backup_requested ? "enabled, keep $max_copies" : 'disabled'));
report($self, \@out, '------------------------------------------------------------');
report($self, \@out, '');
report($self, \@out, 'Starting update check ...');

open my $lock_fh, '>>', $lock_file
    or return failure($self, \@out, "Cannot open lock file $lock_file: $!");

unless (flock($lock_fh, LOCK_EX | LOCK_NB)) {
    report($self, \@out, 'Another check_build process is already running.');
    report($self, \@out, 'Operation cancelled.');
    report($self, \@out, 'Finished with errors.');
    return 1;
}

report($self, \@out, 'Checking DXSpider root directory ...');

unless (defined $main::root && -d $main::root) {
    return failure(
        $self, \@out,
        'DXSpider root directory is not defined or does not exist.'
    );
}

my $configured_root = $main::root;
my $real_root = realpath($configured_root);

unless (defined $real_root && -d $real_root) {
    return failure(
        $self,
        \@out,
        "Cannot resolve the real DXSpider installation path from " .
        "'$configured_root'."
    );
}

report($self, \@out, "  OK  Configured root: $configured_root");
report($self, \@out, "  OK  Resolved root:   $real_root");

my ($backup_dir, $backup_dir_error) =
    resolve_backup_dir($real_root, $requested_backup_dir);

if ($backup_requested && !defined $backup_dir) {
    return failure(
        $self,
        \@out,
        "Cannot select a writable backup directory: $backup_dir_error"
    );
}

if ($backup_requested) {
    report($self, \@out, "Selected backup directory: $backup_dir");
}

report($self, \@out, 'Changing to DXSpider working directory ...');

unless (chdir $real_root) {
    return failure(
        $self, \@out,
        "Cannot change directory to $real_root: $!"
    );
}

report($self, \@out, "  OK  Working directory: $real_root");
report($self, \@out, 'Checking Git working tree ...');

my ($inside_work_tree, $inside_status) =
    capture_git('rev-parse', '--is-inside-work-tree');

unless ($inside_status == 0 && $inside_work_tree eq 'true') {
    return failure(
        $self, \@out,
        "$real_root is not a valid Git working tree."
    );
}

report($self, \@out, '  OK  Valid Git working tree.');
report($self, \@out, "Checking Git remote '$git_remote_name' ...");

my (undef, $remote_status) =
    capture_git('remote', 'get-url', $git_remote_name);

unless ($remote_status == 0) {
    return failure(
        $self, \@out,
        "Git remote '$git_remote_name' does not exist."
    );
}

report($self, \@out, "  OK  Git remote '$git_remote_name' exists.");
report($self, \@out, 'Selecting a working DXSpider repository ...');

my ($selected_url, $remote_commit) = fetch_mojo_from_repositories(
    $self,
    \@out,
    $git_remote_name,
    $remote_ref,
    $git_branch,
    $git_primary_url,
    $git_backup_url
);

unless (defined $selected_url &&
        defined $remote_commit &&
        $remote_commit =~ /\A[0-9a-f]{40,64}\z/) {
    return failure(
        $self,
        \@out,
        'Neither the primary nor the backup repository could provide ' .
        "a valid '$git_branch' branch."
    );
}

$git_selected_url = $selected_url;

report($self, \@out, "  OK  Selected repository: $git_selected_url");
report($self, \@out, "  OK  Remote commit: $remote_commit");
report($self, \@out, 'Reading local repository state ...');

my ($local_commit, $local_commit_status) =
    capture_git('rev-parse', '--verify', 'HEAD^{commit}');

unless ($local_commit_status == 0 &&
        $local_commit =~ /\A[0-9a-f]{40,64}\z/) {
    return failure(
        $self, \@out,
        'The current HEAD does not resolve to a valid commit.'
    );
}

my ($current_branch, $branch_status) =
    capture_git('symbolic-ref', '--quiet', '--short', 'HEAD');

$current_branch = '(detached HEAD)' if $branch_status != 0;

my ($porcelain, $status_status) =
    capture_git('status', '--porcelain', '--untracked-files=no');

unless ($status_status == 0) {
    return failure(
        $self, \@out,
        'Cannot inspect the Git working-tree status.'
    );
}

my $tracked_changes = length($porcelain) ? 1 : 0;
my $commit_changed  = $local_commit ne $remote_commit;
my $wrong_branch    = $current_branch ne $git_branch;

report($self, \@out, "  Local branch : $current_branch");
report($self, \@out, "  Local commit : $local_commit");
report($self, \@out, "  Remote commit: $remote_commit");

if ($tracked_changes) {
    report($self, \@out, '  Tracked local modifications: detected');
}
else {
    report($self, \@out, '  Tracked local modifications: none');
}

# Local tracked modifications are reported, but they do not by themselves
# trigger an update. Backup and restart only occur when the local commit
# differs from origin/mojo or the repository is not on the mojo branch.
my $synchronization_required =
       $commit_changed
    || $wrong_branch;

if (!$synchronization_required) {
    report($self, \@out, '');
    report($self, \@out, 'No new build available.');
    report($self, \@out, "Repository is already synchronized on " .
        "$git_branch at $remote_commit.");

    if ($tracked_changes) {
        report($self, \@out,
            'WARNING: Tracked local modifications were detected.');
        report($self, \@out,
            'No backup was created and the node will not be restarted.');
    }

    report($self, \@out, '');
    report($self, \@out, 'Finished successfully.');

    dbg('DXCron::spawn: repository already synchronized')
        if isdbg('cron');

    # No shutdown occurs in this path, so return the accumulated output
    # normally and let DXCommandmode display it in the console.
    return (1, @out);
}

report($self, \@out, '');

if ($commit_changed) {
    report($self, \@out, 'A different build is available on origin/mojo.');
}

if ($wrong_branch) {
    report($self, \@out, "The repository is on '$current_branch' and will be returned to '$git_branch'.");
}

if ($tracked_changes) {
    report($self, \@out, 'Tracked local modifications will be replaced during synchronization.');
}

if ($backup_requested) {
    report($self, \@out, '');
    report($self, \@out, 'Backup requested.');

    unless (create_backup(
        root        => $real_root,
        backup_dir  => $backup_dir,
        max_copies  => $max_copies,
        self        => $self,
        out         => \@out
    )) {
        report($self, \@out, '');
        report($self, \@out, 'ERROR: Backup failed. Git synchronization has been cancelled.');
        report($self, \@out, 'Repository synchronization was not started.');
        report($self, \@out, 'Finished with errors.');
        return 1;
    }
}
else {
    report($self, \@out, '');
    report($self, \@out, 'Backup skipped by user request.');
    report($self, \@out, 'WARNING: synchronization will continue without creating a backup.');
}

report($self, \@out, '');
report($self, \@out, 'Synchronizing repository ...');
report($self, \@out, "  Switching/resetting local branch '$git_branch' ...");

unless (run_git(
    'checkout',
    '-B',
    $git_branch,
    $remote_ref
)) {
    return failure(
        $self, \@out,
        "Cannot switch/reset local branch '$git_branch' to '$remote_ref'."
    );
}

report($self, \@out, "  Configuring upstream as $git_remote_name/$git_branch ...");

unless (run_git(
    'branch',
    '--set-upstream-to',
    "$git_remote_name/$git_branch",
    $git_branch
)) {
    return failure(
        $self, \@out,
        "Cannot configure '$git_branch' to track " .
        "'$git_remote_name/$git_branch'."
    );
}

report($self, \@out, "  Resetting tracked files to $git_remote_name/$git_branch ...");

unless (run_git('reset', '--hard', $remote_ref)) {
    return failure(
        $self, \@out,
        "Cannot reset '$git_branch' to '$remote_ref'."
    );
}

report($self, \@out, '  OK  Repository synchronization completed.');
report($self, \@out, '');
report($self, \@out, 'Performing final verification ...');

my ($final_branch, $final_branch_status) =
    capture_git('symbolic-ref', '--quiet', '--short', 'HEAD');

unless ($final_branch_status == 0 && $final_branch eq $git_branch) {
    return failure(
        $self, \@out,
        "Final branch verification failed: expected '$git_branch', " .
        "found '$final_branch'."
    );
}

report($self, \@out, "  OK  Branch: $final_branch");

my ($final_commit, $final_commit_status) =
    capture_git('rev-parse', '--verify', 'HEAD^{commit}');

unless ($final_commit_status == 0 &&
        defined $final_commit &&
        defined $remote_commit &&
        $final_commit eq $remote_commit) {
    my $shown_final_commit =
        defined $final_commit && length $final_commit
            ? $final_commit
            : '(undefined)';

    my $shown_remote_commit =
        defined $remote_commit && length $remote_commit
            ? $remote_commit
            : '(undefined)';

    return failure(
        $self, \@out,
        "Final commit verification failed: HEAD '$shown_final_commit' " .
        "does not match '$remote_ref' '$shown_remote_commit' " .
        "(git status $final_commit_status)."
    );
}

report($self, \@out, "  OK  HEAD matches $git_remote_name/$git_branch: $final_commit");

my ($final_url, $final_url_status) =
    capture_git('remote', 'get-url', $git_remote_name);

unless ($final_url_status == 0 &&
        defined $final_url &&
        $final_url eq $git_selected_url) {
    my $shown_final_url =
        defined $final_url && length $final_url
            ? $final_url
            : '(undefined)';

    return failure(
        $self, \@out,
        "Final remote verification failed: expected '$git_selected_url', " .
        "found '$shown_final_url' (git status $final_url_status)."
    );
}

report($self, \@out, "  OK  Remote URL: $final_url");

my ($upstream, $upstream_status) =
    capture_git(
        'rev-parse',
        '--abbrev-ref',
        '--symbolic-full-name',
        '@{upstream}'
    );

unless ($upstream_status == 0 &&
        defined $upstream &&
        $upstream eq "$git_remote_name/$git_branch") {
    my $shown_upstream =
        defined $upstream && length $upstream
            ? $upstream
            : '(undefined)';

    return failure(
        $self, \@out,
        "Final upstream verification failed: expected " .
        "'$git_remote_name/$git_branch', found '$shown_upstream' " .
        "(git status $upstream_status)."
    );
}

report($self, \@out, "  OK  Upstream: $upstream");
report($self, \@out, '');
report($self, \@out, "Repository synchronized successfully: " .
    "$git_branch at $final_commit.");
report($self, \@out, 'DXSpider shutdown/restart has been requested.');
report($self, \@out, 'Finished successfully.');

dbg("DXCron::spawn: synchronized $git_branch at $final_commit")
    if isdbg('cron');

#
# The command normally returns @out to DXCommandmode, which then displays it.
# In this successful update path, however, DXSpider must be shut down immediately.
# Send the complete report directly to the requesting console and write it to
# the DXSpider debug log before executing "shut".
#
eval { DXLog::flushall(); };

DXCron::run_cmd('shut');

# The report was already sent directly. Avoid returning it a second time if
# shutdown processing allows this command to return.
return 1;


sub fetch_mojo_from_repositories
{
    my (
        $self,
        $out,
        $remote_name,
        $remote_ref,
        $branch,
        @urls
    ) = @_;

    for my $url (@urls) {
        report($self, $out, "Trying repository: $url");

        unless (run_git('remote', 'set-url', $remote_name, $url)) {
            report(
                $self,
                $out,
                "  ERROR: Cannot set remote '$remote_name' to '$url'."
            );
            next;
        }

        my ($configured_url, $url_status) =
            capture_git('remote', 'get-url', $remote_name);

        unless ($url_status == 0 &&
                defined $configured_url &&
                $configured_url eq $url) {
            my $shown_url =
                defined $configured_url && length $configured_url
                    ? $configured_url
                    : '(undefined)';

            report(
                $self,
                $out,
                "  ERROR: Remote verification failed for '$url'; " .
                "found '$shown_url' (git status $url_status)."
            );
            next;
        }

        unless (run_git(
            'fetch',
            '--no-tags',
            '--prune',
            $remote_name,
            "+refs/heads/$branch:$remote_ref"
        )) {
            report(
                $self,
                $out,
                "  ERROR: Fetch failed from '$url'."
            );
            next;
        }

        my ($commit, $commit_status) =
            capture_git(
                'rev-parse',
                '--verify',
                "$remote_ref^{commit}"
            );

        unless ($commit_status == 0 &&
                defined $commit &&
                $commit =~ /\A[0-9a-f]{40,64}\z/) {
            my $shown_commit =
                defined $commit && length $commit
                    ? $commit
                    : '(undefined)';

            report(
                $self,
                $out,
                "  ERROR: '$url' did not provide a valid '$branch' " .
                "commit; found '$shown_commit' " .
                "(git status $commit_status)."
            );
            next;
        }

        report($self, $out, "  OK  Repository available: $url");
        return ($url, $commit);
    }

    return;
}


sub resolve_backup_dir
{
    my ($root, $requested) = @_;

    my @candidates;

    if (defined $requested && length $requested) {
        push @candidates, $requested;
    }
    else {
        push @candidates, "$root.backup";

        my $home = (getpwuid($<))[7];

        if (defined $home && length $home && -d $home) {
            my $home_candidate = "$home/spider.backup";

            push @candidates, $home_candidate
                unless grep { $_ eq $home_candidate } @candidates;
        }
    }

    my @errors;

    for my $dir (@candidates) {
        unless (defined $dir && $dir =~ m{\A/}) {
            push @errors, "'$dir' is not an absolute path";
            next;
        }

        if (-e $dir && !-d $dir) {
            push @errors, "'$dir' exists but is not a directory";
            next;
        }

        if (-d $dir) {
            return ($dir, undef) if -r $dir && -w $dir && -x $dir;

            push @errors, "'$dir' is not readable, writable and searchable";
            next;
        }

        my $parent = $dir;
        $parent =~ s{/+[^/]+\z}{};
        $parent = '/' unless length $parent;

        unless (-d $parent) {
            push @errors, "parent directory '$parent' does not exist";
            next;
        }

        unless (-w $parent && -x $parent) {
            push @errors, "parent directory '$parent' is not writable/searchable";
            next;
        }

        return ($dir, undef);
    }

    return (
        undef,
        @errors
            ? join('; ', @errors)
            : 'no backup directory candidates were available'
    );
}


sub create_backup
{
    my %arg = @_;

    my $root = $arg{root};
    my $dir  = $arg{backup_dir};
    my $max  = $arg{max_copies};
    my $self = $arg{self};
    my $out  = $arg{out};

    report($self, $out, 'Backup begins ...');
    report($self, $out, "  Destination: $dir");
    report($self, $out, "  Archives to retain: $max");

    unless (-d $dir) {
        report($self, $out, '  Creating backup directory ...');

        unless (mkdir $dir, 0750) {
            report($self, $out, "  ERROR: Cannot create backup directory '$dir': $!");
            return 0;
        }

        report($self, $out, '  OK  Backup directory created.');
    }
    else {
        report($self, $out, '  OK  Backup directory already exists.');
    }

    unless (-w $dir) {
        report($self, $out, "  ERROR: Backup directory '$dir' is not writable.");
        return 0;
    }

    report($self, $out, '  OK  Backup directory is writable.');

    my @tm = localtime();
    my $date = sprintf(
        '%04d%02d%02d.%02d%02d%02d',
        $tm[5] + 1900,
        $tm[4] + 1,
        $tm[3],
        $tm[2],
        $tm[1],
        $tm[0]
    );

    my $staging_dir = "$dir/$date";
    my $archive     = "$dir/spider.$date.tar.gz";

    if (-e $staging_dir || -e $archive) {
        report($self, $out, "  ERROR: Backup destination already exists for '$date'.");
        return 0;
    }

    my $node_call = defined $main::mycall && length $main::mycall
        ? $main::mycall
        : 'DXSpider';

    is_tg("*$node_call*   Backup Starts");

    my @exclude = (
        '--exclude=local_data/debug',
        '--exclude=local_data/log',
        '--exclude=local_data/spots',
        '--exclude=local_data/wwv',
        '--exclude=local_data/wcy'
    );

    report($self, $out, '  Copying files with rsync ...');

    my $rsync_status = system(
        'rsync',
        '-a',
        @exclude,
        "$root/",
        "$staging_dir/"
    );

    unless (command_succeeded($rsync_status)) {
        report($self, $out, '  ERROR: rsync failed while creating the backup ' .
            '(exit code ' . command_exit_code($rsync_status) . ').');
        return 0;
    }

    report($self, $out, '  OK  Files copied.');
    report($self, $out, '  Creating compressed archive ...');

    my $tar_status = system(
        'tar',
        '-C', $dir,
        '-czf', $archive,
        '--remove-files',
        "$date/"
    );

    unless (command_succeeded($tar_status)) {
        report($self, $out, '  ERROR: tar failed while creating the backup archive ' .
            '(exit code ' . command_exit_code($tar_status) . ').');
        return 0;
    }

    rmdir $staging_dir if -d $staging_dir;

    unless (-f $archive && -s $archive) {
        report($self, $out, "  ERROR: Backup archive '$archive' was not created correctly.");
        return 0;
    }

    report($self, $out, "  OK  Backup archive: $archive");
    report($self, $out, '  Rotating old backup archives ...');

    my @archives = sort glob("$dir/spider.*.tar.gz");
    my $removed = 0;

    while (@archives > $max) {
        my $oldest = shift @archives;

        unless (unlink $oldest) {
            report($self, $out, "  ERROR: Cannot remove old backup '$oldest': $!");
            return 0;
        }

        report($self, $out, "  Removed old backup: $oldest");
        $removed++;
    }

    report($self, $out, $removed
            ? "  OK  Removed $removed old backup archive(s)."
            : '  OK  No old backup archives needed removal.');

    report($self, $out, 'Backup completed successfully.');

    is_tg("*$node_call*   Backup Completed");

    return 1;
}


sub run_git
{
    my @args = @_;

    my $status = system('git', @args);
    return command_succeeded($status);
}


sub capture_git
{
    my @args = @_;

    open my $fh, '-|', 'git', @args
        or return ('', 255);

    local $/;
    my $output = <$fh> // '';

    my $closed = close $fh;
    my $status = $?;

    $output = '' unless defined $output;
    $output =~ s/\s+\z//;

    return ($output, ($closed && command_succeeded($status)) ? 0 : 1);
}


sub command_succeeded
{
    my ($status) = @_;

    return 0 if !defined $status;
    return 0 if $status == -1;
    return 0 if $status & 127;

    return (($status >> 8) == 0) ? 1 : 0;
}


sub command_exit_code
{
    my ($status) = @_;

    return 'unknown' if !defined $status;
    return 'failed to execute' if $status == -1;
    return 'terminated by signal ' . ($status & 127) if $status & 127;

    return $status >> 8;
}


sub failure
{
    my ($self, $out, $message) = @_;

    report($self, $out, '');
    report($self, $out, 'ERROR');
    report($self, $out, $message);
    report($self, $out, 'Operation cancelled.');
    report($self, $out, 'Finished with errors.');

    return 1;
}


#
# Add a message to the command output, write it immediately through DXLog::LogDbg to the
# DXSpider debug and system logs and, when the command is interactive, send it immediately to the
# requesting console. This keeps cron executions in the log while allowing an
# operator to see progress before an automatic shutdown.
#
sub report
{
    my ($self, $out, $message) = @_;

    $message = '' unless defined $message;

    # Preserve the conventional command output array.
    push @$out, $message if $out && ref($out) eq 'ARRAY';

    # Official DXSpider logging path. LogDbg sets the debug category,
    # writes to local_data/debug/YYYY/DDD.dat and also to the system log.
    DXLog::LogDbg('check_build', $message);

    # Do not send progress directly to the interactive channel.
    # During long-running operations the command channel may not display
    # these messages until the command has finished or shutdown has begun.
    # The complete progress report is therefore written to the DXSpider log.
    return 1;
}


sub is_tg
{
    my ($msg) = @_;

    return unless defined &Local::telegram;

    my $result;

    eval {
        $result = Local::telegram($msg);
        1;
    };

    return $result;
}
