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
#  Version : 20260611 v1.12
#
#  Note:
#    Designed to prevent loss of SPOTS/ANN due to incorrect IPs.
#
#  Compatibility:
#    Local IP detection follows the DXAudit hostname-only logic:
#      1) Try hostname -I and accept only valid IP addresses.
#      2) If no valid IP is found, try hostname -i for BusyBox/Alpine.
#      3) Do not use ip addr, to avoid adding fe80:: link-local addresses.
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
    return $ip =~ /:/ ? 1 : 0;
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

sub is_valid_ip {
    my $ip = trim(shift);
    return 0 unless defined $ip && $ip ne "";

    if (is_ipv4($ip)) {
        my @o = ipv4_octets($ip);
        return @o == 4 ? 1 : 0;
    }

    return 1 if is_ipv6($ip);
    return 0;
}

sub add_ips_from_text {
    my ($seen, $txt) = @_;
    my $added = 0;

    for my $ip (split /\s+/, $txt || "") {
        $ip = trim($ip);
        next unless $ip ne "";
        next unless is_valid_ip($ip);

        $seen->{$ip} = 1;
        $added++;
    }

    return $added;
}

sub detect_local_ips {
    my %seen;

    # Always include loopback.
    $seen{"127.0.0.1"} = 1;
    $seen{"::1"} = 1;

    # GNU hostname. BusyBox may print usage text, so only valid IPs count.
    my $out = `hostname -I 2>/dev/null`;
    my $added = add_ips_from_text(\%seen, $out);

    # BusyBox / Alpine fallback. Use only if hostname -I gave no valid IPs.
    if (!$added) {
        $out = `hostname -i 2>/dev/null`;
        add_ips_from_text(\%seen, $out);
    }

    return sort keys %seen;
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
if (is_ipv4($pub_ipv4)) {
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
if (is_ipv6($pub_ipv6)) {
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
my @custom_valid = grep { is_valid_ip($_) } map { trim($_) } @custom;
my @custom_sorted = sort @custom_valid;

my %ip_seen;
my @new_list = grep { $_ ne '' && !$ip_seen{$_}++ }
               (@system_detected, @custom_sorted);

my @old_list = @main::localhost_names;
my %old_map = map { $_ => 1 } @old_list;
my %new_map = map { $_ => 1 } @new_list;

my @added   = grep { !$old_map{$_} } @new_list;
my @removed = grep { !$new_map{$_} } @old_list;

if (@added || @removed) {
    @main::localhost_names = @new_list;
    my $joined = join(' ', @new_list);
    push @out, "Local IPs changes: $joined";
    push @out, "Added: " . join(' ', @added) if @added;
    push @out, "Removed: " . join(' ', @removed) if @removed;
} else {
    my $joined = join(' ', @new_list);
    push @out, "No local IPs change: $joined";
}

# --- Update /spider/scripts/startup ---
my $startup_file = '/spider/scripts/startup';

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
