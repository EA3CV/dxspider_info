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
#  Version : 20250420 v0.8
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
use Fcntl qw(O_RDONLY O_NONBLOCK :flock);
use IPC::Shareable;
use LWP::UserAgent;

# General Configuration
my @nodes = (
    { host => '127.0.0.1', port => 7303 },
    { host => '127.0.0.1', port => 7305 },
);
my $mycall    = 'EA4URE-9';
my $password  = 'notelodire';
my $version   = 'kin_node:0.1';
my $ipv4      = get_public_ip();  # Get the public IP

my $mode       = 'mqtt';  # Options: 'mqtt', 'fifo'
my $fifo_path  = "/tmp/web_conn_fifo";
my $timeout    = 300;
my $interval_pc92c = 7200;
my $interval_pc92k = 3600;

# Global Variables
my (%counter_uses, $last_day, $last_pc92c, $last_pc92k);

my $pc22_seen;
tie $pc22_seen, 'IPC::Shareable', 'pc22_flag', { create => 1, mode => 0666 };
$pc22_seen = 0;

my %conectados;
tie %conectados, 'IPC::Shareable', '/tmp/conectados_shm', { create => 1, mode => 0666 };
%conectados = ();

%counter_uses = ();
$last_day     = (gmtime())[3];
$last_pc92c   = time();
$last_pc92k   = time();

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

sub generate_counter {
    my $now = time;
    my $day = (gmtime($now))[3];

    if ($day != $last_day) {
        %counter_uses = ();
        $last_day = $day;
    }

    my $base_counter = (gmtime($now))[2]*3600 + (gmtime($now))[1]*60 + (gmtime($now))[0];
    $counter_uses{$base_counter}++;
    my $suffix = sprintf(".%02d", $counter_uses{$base_counter});
    return $base_counter . $suffix;
}

sub tx_pc92 {
    my ($type, $call, $ip, $sock) = @_;
    return unless ($type eq 'C' || $pc22_seen);

    my $counter = generate_counter();
    my $pc = $type eq 'A'
        ? "PC92^$mycall^$counter^A^^1$call:$ip^H99^"
        : "PC92^$mycall^$counter^D^^1$call^H99^";

    print $sock "$pc\n";
    log_msg('TX', $pc);
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
    my ($state, $remote_node) = ('login', '');

    while (1) {
        my $now = time();

        if ($now - $last_pc92c >= $interval_pc92c && keys %conectados) {
            send_pc92c($sock);
            $last_pc92c = $now;
        }

        if ($now - $last_pc92k >= $interval_pc92k) {
            send_pc92k($sock);
            $last_pc92k = $now;
        }

        if ($select->can_read(0.1)) {
            my $line = <$sock>;
            last unless defined $line;
            chomp $line;

            if ($line =~ /PC(18|92|20|22|51|11|61)\^/) {
                my $pc = $1;

                log_msg('RX', $line);

                if ($state eq 'login' && $pc == 18) {
                    $state = 'pc92_handshake';
                    send_pc92a_k($sock);
                    next;
                }

                if ($state eq 'pc92_handshake' && $line =~ /^D\s+\Q$mycall\E\s+PC92\^/ && $line =~ /\^K\^/) {
                    $state = 'active';
                }

                if ($pc == 22) {
                    $pc22_seen = 1;
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

    my ($sec, $min, $hour) = (gmtime($epoch))[0..2];
    my $base_counter = $hour * 3600 + $min * 60 + $sec;
    my $ts_int = $base_counter - ($base_counter % 60);
    my $ts_flt = sprintf("%.2f", $base_counter);

    print $sock "PC92^$mycall^$ts_int^A^^5$mycall:$ipv4^H99^\n"; log_msg('TX', 'Enviado PC92 A');
    print $sock "PC92^$mycall^$ts_flt^K^5$mycall:5457:1^0^0^$ipv4^$version^H99^\n"; log_msg('TX', 'Enviado PC92 K');
    print $sock "PC20^\n"; log_msg('TX', 'Enviado PC20');

    $pc22_seen = 1;
}

sub send_pc92c {
    my ($sock) = @_;
    my $counter = generate_counter();

    my $lock_fh = lock_conectados();
    my $payload = join('^', map { "1$_:$conectados{$_}{ip}" } keys %conectados);
    my $pc92c = "PC92^$mycall^$counter^C^5$mycall^$payload^H99^";

    print $sock "$pc92c\n";
    unlock_conectados($lock_fh);
    log_msg('TX', "Enviado PC92C: $pc92c");
}

sub send_pc92k {
    my ($sock) = @_;
    my $counter = generate_counter();
    my $line = "PC92^$mycall^$counter^K^5$mycall:5457:1^0^0^$ipv4^$version^H99^";
    print $sock "$line\n";
    log_msg('TX', "Enviado PC92K: $line");
}

sub lock_conectados {
    open my $fh, '>', '/tmp/conectados_lock' or die "Could not open lock file: $!";
    flock($fh, LOCK_EX) or die "Could not lock file: $!";
    return $fh;
}

sub unlock_conectados {
    my $fh = shift;
    flock($fh, LOCK_UN) or die "Could not unlock file: $!";
    close $fh;
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
                next if $line =~ /^\s*$/;

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

                } elsif ($line =~ /^DESC,(\S+)/) {
                    my $call = uc($1);
                    tx_pc92('D', $call, '', $sock);
                    delete $conectados{$call};
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

sub get_public_ip {
    my $ua = LWP::UserAgent->new;
    my $response = $ua->get('http://api.ipify.org');
    return $response->is_success ? $response->decoded_content : '192.168.255.255';
}
