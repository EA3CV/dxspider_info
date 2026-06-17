#
#  update_ip.pl — Update public and local IPs for DXSpider
#
#  Description:
#    Updates DXSpider runtime IP-related variables:
#      - $main::localhost_alias_ipv4 : public IPv4 address
#      - $main::localhost_alias_ipv6 : public IPv6 address (if any)
#      - @main::localhost_names      : list of known local IPs (127.0.0.1, ::1, etc.)
#
#    This is essential to ensure proper behavior in multi-host, VM, container,
#    or NAT/firewalled environments where DXSpider needs to recognize internal clients.
#
#    It logs and shows changes:
#      - Public IP changes (IPv4 or IPv6)
#      - Local IP additions/removals
#      - Runtime normalisation of @main::localhost_names, including duplicate removal
#
#  Usage:
#    From DXSpider shell (as a self command):
#      set/update_ip                      # Auto-detects current public and local IP
#      set/update_ip 192.168.1.100        # Adds one or more local LAN IPs
#      set/update_ip 10.0.0.5 172.18.0.3
#
#    From crontab (e.g., every 10 minutes):
#      00,10,20,30,40,50 * * * * run_cmd("set/update_ip 192.168.1.100 172.18.0.3")
#
#    Only local IP addresses (not public) should be passed as arguments.
#
#  Installation:
#    Save as: /spider/local_cmd/set/update_ip.pl
#
#  Requirements:
#    - Internet access to detect public IPs (via curl)
#
#  Author  : Kin EA3CV (ea3cv@cronux.net)
#  Version : 20260617 v1.17
#
#  Note:
#    Designed to prevent loss of SPOTS/ANN due to incorrect IPs.
#
#  Compatibility:
#    Local IP detection:
#      1) Prefer ip -o addr show, when available, to include interfaces and tunnels.
#      2) Fall back to hostname -I / hostname -i for minimal containers.
#      3) Always keep loopback 127.0.0.1 and ::1.
#      4) Keep IPv4, IPv6 global and IPv6 ULA addresses.
#      5) Ignore IPv6 link-local fe80::/10, multicast ff00::/8 and unspecified ::.
#      6) Create a timestamped backup before updating /spider/scripts/startup.
#      7) Keep only the latest 5 dxaudit startup backups.
#

use strict;
use warnings;

my ($self, $line) = @_;
my @custom = split(/\s+/, $line || "");
my @out;

sub trim {
    my $v = shift;
    return "" unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    return $v;
}

sub is_ipv4 {
    my $ip = shift;
    return 0 unless defined $ip;
    return $ip =~ /^(?:\d{1,3}\.){3}\d{1,3}$/ ? 1 : 0;
}

sub is_ipv6 {
    my $ip = shift;
    return 0 unless defined $ip;

    # Basic IPv6 sanity check. Avoid accepting arbitrary text such as errors.
    return 0 unless $ip =~ /^[0-9A-Fa-f:.]+$/;
    return 0 unless $ip =~ /:/;

    return 1;
}

sub ipv4_octets {
    my $ip = shift;
    return () unless is_ipv4($ip);
    my @o = split /\./, $ip;
    return () unless @o == 4;
    for my $x (@o) {
        return () unless $x =~ /^\d+$/ && $x >= 0 && $x <= 255;
    }
    return @o;
}

sub is_ipv6_link_local {
    my $ip = shift;
    return 0 unless is_ipv6($ip);
    return lc($ip) =~ /^fe[89ab][0-9a-f]*:/ ? 1 : 0;  # fe80::/10
}

sub is_ipv6_unique_local {
    my $ip = shift;
    return 0 unless is_ipv6($ip);
    return lc($ip) =~ /^f[cd][0-9a-f]*:/ ? 1 : 0;     # fc00::/7
}

sub is_ipv6_multicast {
    my $ip = shift;
    return 0 unless is_ipv6($ip);
    return lc($ip) =~ /^ff[0-9a-f]*:/ ? 1 : 0;        # ff00::/8
}

sub is_private_or_local_ipv4 {
    my $ip = shift;
    my @o = ipv4_octets($ip);
    return 1 unless @o == 4;

    return 1 if $o[0] == 0;
    return 1 if $o[0] == 10;
    return 1 if $o[0] == 127;
    return 1 if $o[0] == 169 && $o[1] == 254;
    return 1 if $o[0] == 172 && $o[1] >= 16 && $o[1] <= 31;
    return 1 if $o[0] == 192 && $o[1] == 168;
    return 1 if $o[0] == 100 && $o[1] >= 64 && $o[1] <= 127; # CGNAT
    return 1 if $o[0] >= 224; # multicast/reserved

    return 0;
}

sub is_public_ip {
    my $ip = trim(shift);
    return 0 unless defined $ip && $ip ne "";

    if (is_ipv4($ip)) {
        return is_private_or_local_ipv4($ip) ? 0 : 1;
    }

    if (is_ipv6($ip)) {
        return 0 if $ip eq "::" || $ip eq "::1";
        return 0 if is_ipv6_link_local($ip);
        return 0 if is_ipv6_unique_local($ip);
        return 0 if is_ipv6_multicast($ip);
        return 1;
    }

    return 0;
}

sub is_valid_local_ip {
    my $ip = trim(shift);
    return 0 unless defined $ip && $ip ne "";

    if (is_ipv4($ip)) {
        my @o = ipv4_octets($ip);
        return @o == 4 ? 1 : 0;
    }

    if (is_ipv6($ip)) {
        return 1 if $ip eq "::1";          # keep loopback
        return 0 if $ip eq "::";           # unspecified
        return 0 if is_ipv6_link_local($ip);
        return 0 if is_ipv6_multicast($ip);

        # Keep global IPv6 and ULA fc00::/7 because they can be used on
        # LAN/VPN/tunnel paths and may need alias_localhost mapping.
        return 1;
    }

    return 0;
}

sub is_valid_ip {
    return is_valid_local_ip(@_);
}

sub add_ips_from_text {
    my ($seen, $txt) = @_;
    my $added = 0;

    for my $ip (split /\s+/, $txt || "") {
        $ip = trim($ip);
        next unless $ip ne "";
        next unless is_valid_local_ip($ip);

        $seen->{$ip} = 1;
        $added++;
    }

    return $added;
}

sub collect_ips_from_ip_addr {
    my ($seen) = @_;

    my $out = `ip -o addr show 2>/dev/null`;
    return 0 unless defined $out && $out ne "";

    my $added = 0;

    for my $line (split /\n/, $out) {
        # Normal address or point-to-point local address:
        #   inet 192.168.2.10/32 ...
        #   inet 192.168.2.18 peer 192.168.2.1/32 ...
        if ($line =~ /\binet6?\s+([0-9A-Fa-f:.]+)(?:\/|\s+peer\s+)/) {
            my $ip = trim($1);
            if (is_valid_local_ip($ip)) {
                $seen->{$ip} = 1;
                $added++;
            }
        }

        # Point-to-point peer address (Fedora/slip/tunnel/etc.)
        if ($line =~ /\speer\s+([0-9A-Fa-f:.]+)\//) {
            my $peer = trim($1);
            if (is_valid_local_ip($peer)) {
                $seen->{$peer} = 1;
                $added++;
            }
        }
    }

    return $added;
}

sub detect_local_ips {
    my %seen;

    # Always include loopback.
    $seen{"127.0.0.1"} = 1;
    $seen{"::1"} = 1;

    # Prefer ip addr because it includes tunnel and virtual interface addresses.
    # We filter IPv6 link-local/multicast/unspecified afterwards.
    my $added = collect_ips_from_ip_addr(\%seen);

    # Fallback for minimal containers where iproute2 is not installed.
    if (!$added) {
        my $out = `hostname -I 2>/dev/null`;
        $added = add_ips_from_text(\%seen, $out);

        if (!$added) {
            $out = `hostname -i 2>/dev/null`;
            add_ips_from_text(\%seen, $out);
        }
    }

    return sort keys %seen;
}

sub prune_startup_backups {
    my ($startup_file, $keep) = @_;
    $keep ||= 5;

    my $pattern = $startup_file . '.dxaudit-backup-*';
    my @backups = grep { -f $_ } glob($pattern);

    return 0 if @backups <= $keep;

    # Newest first by modification time, fallback to filename for deterministic order.
    @backups = sort {
        ((stat($b))[9] || 0) <=> ((stat($a))[9] || 0) || $b cmp $a
    } @backups;

    my @remove = @backups[$keep .. $#backups];
    my $removed = 0;

    for my $file (@remove) {
        if (unlink $file) {
            $removed++;
        }
    }

    return $removed;
}

# Get public IPv4 and IPv6 separately.
my $pub_ipv4 = `curl -4 -s ifconfig.me 2>/dev/null`;
chomp($pub_ipv4);
$pub_ipv4 = trim($pub_ipv4);

my $pub_ipv6 = `curl -6 -s ifconfig.me 2>/dev/null`;
chomp($pub_ipv6);
$pub_ipv6 = trim($pub_ipv6);

# --- IPv4 ---
my $old_ipv4 = $main::localhost_alias_ipv4 || '';
if (is_public_ip($pub_ipv4) && is_ipv4($pub_ipv4)) {
    if ($pub_ipv4 ne $old_ipv4) {
        $main::localhost_alias_ipv4 = $pub_ipv4;
        push @out, "\nPublic IPv4 change: $pub_ipv4 (previous $old_ipv4)";
    } else {
        push @out, "No public IPv4 change: $pub_ipv4";
    }
} else {
    push @out, "No public IPv4 available";
}

# --- IPv6 ---
my $old_ipv6 = $main::localhost_alias_ipv6 || '';
if (is_public_ip($pub_ipv6) && is_ipv6($pub_ipv6)) {
    if ($pub_ipv6 ne $old_ipv6) {
        $main::localhost_alias_ipv6 = $pub_ipv6;
        push @out, "Public IPv6 change: $pub_ipv6 (previous $old_ipv6)";
    } else {
        push @out, "No public IPv6 change: $pub_ipv6";
    }
} else {
    push @out, "No public IPv6 available";
}

# --- Local IPs ---
my @system_detected = detect_local_ips();

# Only valid local IPs passed as arguments are accepted.
my @custom_valid = grep { is_valid_local_ip($_) } map { trim($_) } @custom;
my @custom_sorted = sort @custom_valid;

my %ip_seen;
my @new_list = grep { $_ ne '' && !$ip_seen{$_}++ }
               (@system_detected, @custom_sorted);

my @old_list = @main::localhost_names;
my %old_map = map { $_ => 1 } @old_list;
my %new_map = map { $_ => 1 } @new_list;

my @added   = grep { !$old_map{$_} } @new_list;
my @removed = grep { !$new_map{$_} } @old_list;

my %old_count;
$old_count{$_}++ for @old_list;
my @duplicates = sort grep { $old_count{$_} > 1 } keys %old_count;

# Always normalise the runtime variable, even when there are no logical
# additions/removals. This removes duplicates already loaded in memory and keeps
# sh/var consistent with what is written to /spider/scripts/startup.
@main::localhost_names = @new_list;

my $joined = join(' ', @new_list);
if (@added || @removed) {
    push @out, "Local IPs changes: $joined";
    push @out, "Added: " . join(' ', @added) if @added;
    push @out, "Removed: " . join(' ', @removed) if @removed;
} elsif (@duplicates) {
    push @out, "Local IPs normalised: $joined";
    push @out, "Removed duplicate entries: " . join(' ', @duplicates);
} else {
    push @out, "No local IPs change: $joined";
}

# --- Update /spider/scripts/startup ---
my $startup_file = '/spider/scripts/startup';

if (-e $startup_file) {
    my $backup_file = $startup_file . ".dxaudit-backup-" . time();
    if (open(my $src_fh, '<', $startup_file)) {
        if (open(my $bak_fh, '>', $backup_file)) {
            while (my $line = <$src_fh>) {
                print $bak_fh $line;
            }
            close($bak_fh);
            push @out, "Backup created: $backup_file";
        } else {
            push @out, "WARNING: cannot create backup file: $backup_file";
        }
        close($src_fh);
    } else {
        push @out, "WARNING: cannot read startup file for backup: $startup_file";
    }

    my $removed_backups = prune_startup_backups($startup_file, 5);
    push @out, "Old backups removed: $removed_backups" if $removed_backups;
}

open(my $in, '<', $startup_file) or die "Cannot open $startup_file: $!";
my @lines = <$in>;
close($in);

my $ipv4_line  = "set/var \$main::localhost_alias_ipv4 = '$main::localhost_alias_ipv4';\n";
my $ipv6_line  = "set/var \$main::localhost_alias_ipv6 = '$main::localhost_alias_ipv6';\n";
my $names_line = "set/var \@main::localhost_names = qw(@main::localhost_names);\n";

@lines = grep {
    !/\$main::localhost_alias_ipv4/ &&
    !/\$main::localhost_alias_ipv6/ &&
    !/\@main::localhost_names/
} @lines;

push @lines, $ipv4_line, $ipv6_line, $names_line;

open(my $out_fh, '>', $startup_file) or die "Cannot write to $startup_file: $!";
print $out_fh @lines;
close($out_fh);

push @out, "Updated /spider/scripts/startup with current IP definitions.";

return (1, @out);
