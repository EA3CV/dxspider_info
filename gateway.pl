#!/usr/bin/perl

#
#  gateway.pl — Lightweight DXSpider node to inject PC92 messages from MQTT
#
#  Description:
#    This script acts as a minimal DXSpider node. It connects to one or more
#    full DXSpider nodes and sends PC92 messages (A/D/C) based on real-time
#    MQTT events received from a web frontend or other data source.
#
#    It manages login, handshake, connection monitoring and message formatting
#    according to DXSpider's PC protocol. Designed for lightweight integration.
#
#  Usage:
#    Run the script as a background process or service. Multiple DXSpider
#    destination nodes can be configured and used in parallel.
#
#  Installation:
#    Save as: /spider/perl/gateway.pl
#    Recommended to create a systemd service or init script for auto-start.
#
#    This script acts as a node. You must configure it on the main DXSpider node with:
#      set/spider <node>
#      set/register <node>
#      set/password <node> <password>
#
#  Requirements:
#    - Perl modules: IO::Socket::INET, Time::HiRes, POSIX, JSON, Net::MQTT::Simple
#    - MQTT broker reachable at configured IP and topic structure
#
#  Config:
#    $use_mqtt         = 1;           # Enable MQTT integration
#    $timeout          = 300;         # Disconnection timeout for users (in seconds)
#    $interval_pc92c   = 1800;        # Interval to send PC92^C summary (in seconds)
#
#  Author  : Kin EA3CV (ea3cv@cronux.net)
#  Version : 20250418 v1.0
#
#  License : This software is released under the GNU General Public License v3.0 (GPLv3)
#

use strict;
use warnings;
use IO::Socket::INET;
use Time::HiRes qw(time sleep);
use POSIX qw(strftime);
use JSON;
use Net::MQTT::Simple;

# General Configuration
my @nodes = (
    { host => '127.0.0.1', port => 7303 },
    { host => '127.0.0.1', port => 7305 },
);
my $mycall   = 'EA4URE-9';
my $password = 'notelodire';
my $version  = 'lightnode:0.1';
my $ipv6     = '2a01:4f8:1c1b::1';

my $use_mqtt = 1;
my $timeout  = 300;
my $interval_pc92c = 1800;

# Global Variables
my (%conectados, %counter_uses, $last_day, $last_pc92c);
%counter_uses = ( A => {}, D => {}, C => {} );
$last_day = (gmtime())[3];
$last_pc92c = time();

# Main Loop
while (1) {
    foreach my $node (@nodes) {
        my $sock = connect_node($node->{host}, $node->{port});
        next unless $sock;

        if ($use_mqtt) {
            if (fork() == 0) {
                run_mqtt_loop($sock);
                exit 0;
            }
        }

        eval {
            handle_node($sock);
        };

        log_msg('**', "Disconnected from $node->{host}:$node->{port}, retrying in 5s...");
        close $sock if $sock;
        sleep 5;
    }
}

sub connect_node {
    my ($host, $port) = @_;
    my $sock = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 10
    );

    unless ($sock) {
        log_msg('**', "Could not connect to $host:$port - $!");
        return;
    }

    $sock->autoflush(1);
    log_msg('**', "Connected to $host:$port");

    print $sock "$mycall\n";
    sleep 1;
    print $sock "$password\n" if $password;
    log_msg('**', "Login sent as $mycall");

    return $sock;
}

sub handle_node {
    my ($sock) = @_;
    my ($state, $pc22_seen, $remote_node) = ('login', 0, '');

    while (my $line = <$sock>) {
        chomp $line;
        my $now = time;

        if ($line =~ /PC(18|92|20|22|51|11|61)\^/) {
            my $pc = $1;

            if ($pc == 92 && $pc22_seen) {
                next;
            }

            log_msg('RX', $line);

            if ($state eq 'login' && $pc == 18) {
                $state = 'pc92_handshake';
                log_msg('**', "PC18 received, sending PC92 handshake...");
                send_pc92a_k($sock);
                next;
            }

            if ($state eq 'pc92_handshake' && $line =~ /^D\s+\Q$mycall\E\s+PC92\^/ && $line =~ /\^K\^/) {
                $state = 'active';
                log_msg('**', "Handshake completed. State -> ACTIVE");
            }

            if ($pc == 22) {
                $pc22_seen = 1;
                log_msg('**', "PC22 detected. Future incoming PC92 will be ignored.");
            }

            if ($pc == 92 && !$remote_node && $line =~ /^PC92\^([^\^]+)\^\d+\^A\^\^/) {
                $remote_node = $1;
            }

            if ($pc == 51 && $line =~ /^PC51\^$mycall\^([^\^]+)\^1\^/) {
                my $dest = $1;
                my $reply = "PC51^$dest^$mycall^0^";
                print $sock "$reply\n";
                log_msg('TX', $reply);
            }
        }

        if ($now - $last_pc92c >= $interval_pc92c && keys %conectados) {
            send_pc92c($sock);
            $last_pc92c = $now;
        }
    }
    die "Connection lost";
}

sub send_pc92a_k {
    my ($sock) = @_;
    my $epoch = time();
    my $ts_int = int($epoch - int($epoch) % 60);
    my $ts_flt = sprintf("%.2f", $epoch - int($epoch) % 60);

    foreach my $line (
        "PC92^$mycall^$ts_int^A^^5$mycall:$ipv6^H99^",
        "PC92^$mycall^$ts_flt^K^5$mycall:5457:1^0^0^$ipv6^$version^H99^",
        "PC20^"
    ) {
        print $sock "$line\n";
        log_msg('TX', $line);
    }
}

sub send_pc92c {
    my ($sock) = @_;
    my $now = time;
    my $base_counter = (gmtime($now))[2]*3600 + (gmtime($now))[1]*60 + (gmtime($now))[0];
    $counter_uses{C}{$base_counter}++;
    my $suffix = sprintf(".%02d", $counter_uses{C}{$base_counter});
    my $counter = $base_counter . $suffix;
    my $payload = join('^', map { "1$_:$conectados{$_}{ip}" } keys %conectados);
    my $pc92c = "PC92^$mycall^$counter^C^5$mycall^$payload^^H99^";

    print $sock "$pc92c\n";
    log_msg('TX', $pc92c);
}

sub tx_pc92 {
    my ($type, $call, $ip, $sock) = @_;
    my $now = time;
    my $day = (gmtime($now))[3];

    if ($day != $last_day) {
        %counter_uses = ( A => {}, D => {}, C => {} );
        $last_day = $day;
    }

    my $base_counter = (gmtime($now))[2]*3600 + (gmtime($now))[1]*60 + (gmtime($now))[0];
    $counter_uses{$type}{$base_counter}++;
    my $suffix = sprintf(".%02d", $counter_uses{$type}{$base_counter});
    my $counter = $base_counter . $suffix;

    my $pc = $type eq 'A' ? "PC92^$mycall^$counter^A^^1$call:$ip^H99^" : "PC92^$mycall^$counter^D^^1$call^H99^";
    print $sock "$pc\n";
    log_msg('TX', $pc);
}

sub run_mqtt_loop {
    my ($sock) = @_;
    my $mqtt;

    while (1) {
        eval {
            $mqtt = Net::MQTT::Simple->new('192.168.1.121:1883');
            $mqtt->subscribe('api/heartbeat/socio' => sub {
                my ($topic, $message) = @_;
                my $data = eval { decode_json($message) };
                return unless $data and $data->{call};

                my $call = uc($data->{call});
                my $now  = time;
                my @ips = map { s/^\s+|\s+\$//gr } split /,/, $data->{ip};

                for my $i (0..$#ips) {
                    my $ip = $ips[$i];
                    my $full_call = $i == 0 ? $call : "$call-" . (19 + $i);

                    unless (exists $conectados{$full_call}) {
                        tx_pc92('A', $full_call, $ip, $sock);
                        $conectados{$full_call}{start} = $now;
                    }

                    $conectados{$full_call}{ip}   = $ip;
                    $conectados{$full_call}{last} = $now;
                }
            });

            while (1) {
                $mqtt->tick();
                my $now = time;
                for my $call (keys %conectados) {
                    if ($now - $conectados{$call}{last} > $timeout) {
                        tx_pc92('D', $call, '', $sock);
                        delete $conectados{$call};
                    }
                }
                sleep 1;
            }
        };

        log_msg('**', "MQTT error: $@. Retrying in 10s...");
        sleep 10;
    }
}

sub log_msg {
    my ($type, $msg) = @_;
    my $now = strftime("%H:%M:%S", localtime);
    print "[$now][$type] $msg\n";
}
