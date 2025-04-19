#!/usr/bin/perl

#
#  gateway.pl — Lightweight DXSpider node to inject PC92 messages from MQTT or FIFO
#
#  Description:
#    This script acts as a minimal DXSpider node. It connects to one or more
#    full DXSpider nodes and sends PC92 messages (A/D/C) based on real-time
#    events received via MQTT or a named FIFO pipe.
#
#    It handles login, handshake, periodic PC92C summary reports, connection
#    timeouts, and protocol message formatting. Only one input mode should be used.
#
#    PC92A is sent once when a user connects, PC92D after inactivity,
#    and PC92C every configured interval summarizing currently connected users.
#
#  Usage:
#    Run the script as a background process or systemd service.
#    Multiple destination DXSpider nodes can be defined and will be used in order.
#
#  Installation:
#    Save as: /spider/perl/gateway.pl
#    Recommended to install as a systemd service using install_gateway_service.sh
#
#    This script acts as a DXSpider node. Configure it on the main DXSpider node with:
#      set/spider <node>
#      set/register <node>
#      set/password <node> <password>
#
#  Requirements:
#    - Perl modules: IO::Socket::INET, IO::Select, Time::HiRes, POSIX, JSON,
#                    Net::MQTT::Simple, Fcntl
#
#  Input modes:
#    Set the input mode:
#      my $mode = 'mqtt';    # Options: 'mqtt', 'fifo'
#
#    MQTT:
#      Topic: api/heartbeat/socio
#      Payload (JSON):
#        { "call": "EA3XYZ", "ip": "1.2.3.4[,ipv6]", "ts": 1713456789, "svc": "1", "ident": 1 }
#
#    FIFO:
#      Path: /tmp/web_conn_fifo
#      Lines:
#        CONN,<CALL>,<IP>     triggers PC92A
#        DESC,<CALL>          triggers PC92D
#
#  Config:
#    $mode            = 'mqtt';            # Select input method: 'mqtt' or 'fifo'
#    $fifo_path       = "/tmp/web_conn_fifo";
#    $timeout         = 300;               # Disconnection timeout for users (seconds)
#    $interval_pc92c  = 450;               # Interval to send PC92^C summary (seconds)
#
#  Author  : Kin EA3CV (ea3cv@cronux.net)
#  Version : 20250418 v0.4
#
#  License : This software is released under the GNU General Public License v3.0 (GPLv3)
#

#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Time::HiRes qw(time sleep);
use POSIX qw(strftime);
use JSON;
use Net::MQTT::Simple;
use Fcntl qw(:flock :DEFAULT);
use LWP::Simple;

# General Configuration
my @nodes = (
    { host => '127.0.0.1', port => 7303 },
    { host => '127.0.0.1', port => 7305 },
);
my $mycall    = 'NODE-9';
my $password  = 'xxxxxxxx';
my $version   = 'lightnode:0.1';

# Try to get public IP (IPv4)
my $ipv4 = get("http://api.ipify.org");

# If the public IP cannot be obtained, assign a default value
if (!$ipv4) {
    $ipv4 = "192.168.100.1";
    print "Unable to obtain public IP, assigning default IP: $ipv4\n";
} else {
    print "Your public IP is: $ipv4\n";
}

my $mode = 'mqtt';  # Options: 'mqtt', 'fifo'
my $fifo_path = "/tmp/web_conn_fifo";
my $timeout = 300;
my $interval_pc92c = 3600;

# Global Variables
my (%conectados, %counter_uses, $last_day, $last_pc92c);
%counter_uses = ( A => {}, D => {}, C => {} );
$last_day     = (gmtime())[3];
$last_pc92c   = time();

# At the start, load the state of connected from memory
load_conectados();

# Main Loop
while (1) {
    foreach my $node (@nodes) {
        my $sock = connect_node($node->{host}, $node->{port});
        next unless $sock;

        if ($mode eq 'mqtt') {
            if (fork() == 0) {
                run_mqtt_loop($sock);
                exit 0;
            }
        } elsif ($mode eq 'fifo') {
            if (fork() == 0) {
                run_fifo_loop($sock);
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
    my $select = IO::Select->new($sock);
    my ($state, $pc22_seen, $remote_node) = ('login', 0, '');

    while (1) {
        my $now = time();

        if ($now - $last_pc92c >= $interval_pc92c && keys %conectados) {
            send_pc92c($sock);
            $last_pc92c = $now;
        }

        if ($select->can_read(0.1)) {
            my $line = <$sock>;
            last unless defined $line;
            chomp $line;

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
        "PC92^$mycall^$ts_int^A^^5$mycall:$ipv4^H99^",  # Use ipv4 instead of ipv6
        "PC92^$mycall^$ts_flt^K^5$mycall:5457:1^0^0^$ipv4^$version^H99^",  # ipv4
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

    my $pc = $type eq 'A'
        ? "PC92^$mycall^$counter^A^^1$call:$ip^H99^"
        : "PC92^$mycall^$counter^D^^1$call^H99^";

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

                    my $already = exists $conectados{$full_call};
                    $conectados{$full_call}{ip}   = $ip;
                    $conectados{$full_call}{last} = $now;

                    unless ($already) {
                        $conectados{$full_call}{start} = $now;
                        tx_pc92('A', $full_call, $ip, $sock);
                    }
                }

                # Save the state after modifying %conectados in memory
                save_conectados();
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

sub run_fifo_loop {
    my ($sock) = @_;

    while (1) {
        unless (-p $fifo_path) {
            unlink $fifo_path;
            system("mkfifo", $fifo_path);
            log_msg('**', "FIFO $fifo_path created");
        }

        sysopen(my $fh, $fifo_path, O_RDONLY | O_NONBLOCK) or do {
            log_msg('**', "Failed to open FIFO $fifo_path: $!");
            sleep 5;
            next;
        };

        log_msg('**', "FIFO $fifo_path opened for reading");
        my $selector = IO::Select->new($fh);

        while (1) {
            unless (-p $fifo_path) {
                log_msg('**', "FIFO $fifo_path was removed, restarting...");
                last;
            }

            if ($selector->can_read(0.1)) {
                my $line = <$fh>;

                unless (defined $line) {
                    log_msg('**', "FIFO closed (writer end disappeared), reopening...");
                    last;
                }

                chomp $line;
                next if $line =~ /^\s*\$/;

                if ($line =~ /^CONN,(\S+),(\S+)/) {
                    my ($call, $ip) = (uc($1), $2);
                    my $now = time;

                    my $already = exists $conectados{$call};
                    $conectados{$call}{ip}   = $ip;
                    $conectados{$call}{last} = $now;

                    unless ($already) {
                        $conectados{$call}{start} = $now;
                        tx_pc92('A', $call, $ip, $sock);
                    }

                    # Save the state after modifying %conectados in memory
                    save_conectados();

                } elsif ($line =~ /^DESC,(\S+)/) {
                    my $call = uc($1);
                    tx_pc92('D', $call, '', $sock);
                    delete $conectados{$call};

                    # Save the state after modifying %conectados in memory
                    save_conectados();
                }
            }
        }

        close $fh;
        sleep 1;
    }
}

sub log_msg {
    my ($type, $msg) = @_;
    my $now = strftime("%H:%M:%S", localtime);
    print "[$now][$type] $msg\n";
}

sub save_conectados {
    # Save the state of %conectados in memory with Storable
    nstore(\%conectados, '/tmp/conectados.dat');
    log_msg('**', "State of %conectados saved in memory");
}

sub load_conectados {
    # Load the state of %conectados from memory
    if (-e '/tmp/conectados.dat') {
        %conectados = %{ retrieve('/tmp/conectados.dat') };
        log_msg('**', "State of %conectados loaded from memory");
    }
}
