#
#  set/update_ip.pl                                                              
#                                                                            
#  Description:                                                              
#    This script updates two key DXSpider startup variables:                
#      - $main::localhost_alias_ipv4 : current public IPv4 address          
#      - @main::localhost_names      : list of local IPs (127.0.0.1, ::1, etc.)
#
#     These values are automatically inserted or updated in:                 
#      - /spider/scripts/startup                                            
#
#    Intended to run periodically (e.g. via cron) to reflect network changes,
#    especially in dynamic IP environments or container setups (e.g. Docker).
#
#  Installation:                                                             
#    Save this script as /spider/local_cmd/set/update_ip.pl                     
#
#  Requirements:                                                             
#    Perl module 'Path::Tiny':                                               
#      Debian/Ubuntu: apt install libpath-tiny-perl                          
#      CPAN         : cpanm Path::Tiny                                       
#
#  Usage from DXSpider (as self command):
#    From DXSpider shell: set/update_ip 192.168.1.5 10.0.0.5
#
#  Crontab usage:
#    To update every 10 minutes, add this to your crontab:
#      00,10,20,30,40,50 * * * * run_cmd("set/update_ip 192.168.1.5 10.0.0.5")
#
#  Author   : Kin EA3CV (ea3cv@cronux.net)                                  
#
#  20250405 v1.4
#        - Added support for custom IPs passed via command-line arguments
#          You can pass additional local IPs as arguments (e.g., private LAN, Docker)
#

use 5.10.1;
use Path::Tiny qw(path);
use strict;
use warnings;

my ($self, $line) = @_;
my @out;

my @custom_ips = split(/\s+/, $line);

my $ip = `curl -s ifconfig.me`;
chomp($ip);
$ip = "'$ip'";
my $var1 = 'set/var $main::localhost_alias_ipv4 =';
my $find1 = 'localhost_alias_ipv4';
startup($var1, $ip, $find1);
push @out, "$var1 $ip";

my $ips = `hostname -I`;    # -i para Docker, -I para el resto
$ips =~ s/\s+\$//;

my @default_local = qw(127.0.0.1 ::1);
my @hostname_ips = split(/\s+/, $ips);
my @all_ips = (@default_local, @hostname_ips, @custom_ips);
my $var2 = 'set/var @main::localhost_names qw(' . join(' ', @all_ips) . ')';
my $find2 = 'localhost_names';
startup($var2, '', $find2);
push @out, $var2;

cmd_import($out[0], $out[1]);

return (1, @out);

sub cmd_import {
    my ($msg1, $msg2) = @_;
    my $dir = "/spider/cmd_import";
    mkdir $dir unless -d $dir;
    open(my $fh, '>', "$dir/update_ip") or return;
    say $fh $msg1;
    say $fh $msg2;
    close $fh;
}

sub startup {
    my ($var, $arg, $find) = @_;
    my $file = '/spider/scripts/startup';
    my @lines = path($file)->lines_utf8;
    my $found = 0;

    foreach my $line (@lines) {
        if ($line =~ m/$find/) {
            $line =~ s/.*$find.*/$var $arg/;
            $found = 1;
        }
    }

    path($file)->spew_utf8(@lines) if $found;
    unless ($found) {
        path($file)->append_utf8("\n#\n$var $arg\n");
    }
}
