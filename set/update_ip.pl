#
#  update_ip.pl — Update public and local IPs for DXSpider
#
#  Description:
#    Updates two key DXSpider runtime variables:
#     - $main::localhost_alias_ipv4 : current public IPv4 address
#     - @main::localhost_names      : list of local IPs (127.0.0.1, ::1, etc.)
#
#    Logs and shows changes if any (added/removed IPs).
#
#  Usage:
#    From DXSpider shell (as a self command):
#      set/update_ip 192.168.1.10 10.0.0.5
#
#    From crontab (e.g., every 10 minutes):
#      00,10,20,30,40,50 * * * * run_cmd("set/update_ip 192.168.1.10 10.0.0.5")
#
#    ⚠️ Only local IP addresses (not public IPs) can be passed as arguments.
#
#  Installation:
#    Save as: /spider/local_cmd/set/update_ip.pl
#
#  Requirements:
#    - Internet access required to detect public IP
#
#  Author : Kin EA3CV ea3cv@cronux.net
#  Version: 20250407 v1.6
#

use strict;
use warnings;

my ($self, $line) = @_;
my @custom_ips = split(/\s+/, $line);

my @out;

# --- Public IP ---

my $new_public_ip = `curl -s ifconfig.me`;
chomp($new_public_ip);
my $old_public_ip = $main::localhost_alias_ipv4;

if ($new_public_ip && $new_public_ip ne $old_public_ip) {
    $main::localhost_alias_ipv4 = $new_public_ip;
#    LogDbg("update_ip: Public IP changed from $old_public_ip to $new_public_ip");
    push @out, "\nPublic IP change: $new_public_ip (previous $old_public_ip)";
} else {
#    LogDbg("update_ip: No change in public IP ($new_public_ip)");
    push @out, "\nNo public IP change: $new_public_ip";
}

# --- Local IPs ---

my @system_ips = qw(127.0.0.1 ::1);
my $hostname_ips = `hostname -I`;
my @detected = grep { $_ ne '' } split(/\s+/, $hostname_ips);
my @custom_sorted = sort @custom_ips;

my @combined = (@system_ips, @detected, @custom_sorted);
my %seen;
@combined = grep { !$seen{$_}++ } @combined;

my @old_list = @main::localhost_names;
my %old_map = map { $_ => 1 } @old_list;
my %new_map = map { $_ => 1 } @combined;

my @added   = grep { !$old_map{$_} } @combined;
my @removed = grep { !$new_map{$_} } @old_list;

if (@added || @removed) {
    @main::localhost_names = @combined;

#    LogDbg("update_ip: Local IPs updated: +@added -@removed");
    push @out, "Local IPs changes: @main::localhost_names";
} else {
#    LogDbg("update_ip: No changes to local IPs");
    push @out, "No local IPs change: @main::localhost_names";
}

return (1, @out);
