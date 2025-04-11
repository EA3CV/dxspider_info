#
# File: /spider/local/Local.pm
#
# Send all incoming traffic to MQTT/JSON
# From build 431 and up
#
# Modified by Kin EA3CV with the inestimable help of Dirk
# ea3cv@cronux.net
#
# 20250410 v7.0
#

package Local;

use DXVars;
use DXDebug;
use DXUtil;
use JSON;
use DXLog;
use 5.10.1;
use Net::MQTT::Simple;
use Net::SMTP;
use Net::SMTP::SSL;
use strict;

# declare any global variables you use in here
use vars qw{$mqtt $json};

# called at initialisation time
sub init {
    $mqtt = Net::MQTT::Simple->new("localhost:1883");
}

# called once every second
# sub process {
# }

# called just before the ending of the program
# sub finish {
# }

sub pcprot {
    my ($self, $pcno, $line, @field) = @_;

    SWITCH: {
        # if ($pcno == 10) { last SWITCH; }

        if ($pcno == 11 || $pcno == 26 || $pcno == 61) {
            my %mqtt_spot = ('SPOTS' => $line);
            $json = JSON->new->canonical(1)->encode(\%mqtt_spot);
            $mqtt->publish("spider/raw/nodo-6", $json);
            return 0;
            last SWITCH;
        }

        if ($pcno == 12 || $pcno == 93) {
            my %mqtt_spot = ('ANN' => $line);
            $json = JSON->new->canonical(1)->encode(\%mqtt_spot);
            # $mqtt->publish("spider/raw/nodo-6", $json);
            ## return 0;
            last SWITCH;
        }

        # if ($pcno == 13) { last SWITCH; }
        # if ($pcno == 14) { last SWITCH; }
        # if ($pcno == 15) { last SWITCH; }
        # if ($pcno == 16) { last SWITCH; }
        # if ($pcno == 17) { last SWITCH; }
        # if ($pcno == 18) { last SWITCH; }
        # if ($pcno == 19) { last SWITCH; }
        # if ($pcno == 20) { last SWITCH; }
        # if ($pcno == 21) { last SWITCH; }
        # if ($pcno == 22) { last SWITCH; }

        if ($pcno == 23 || $pcno == 27) {
            my %mqtt_spot = ('WWV' => $line);
            $json = JSON->new->canonical(1)->encode(\%mqtt_spot);
            # $mqtt->publish("spider/raw/nodo-6", $json);
            ## return 0;
            last SWITCH;
        }

        if ($pcno == 73) {
            my %mqtt_spot = ('WCY' => $line);
            $json = JSON->new->canonical(1)->encode(\%mqtt_spot);
            # $mqtt->publish("spider/raw/nodo-6", $json);
            ## return 0;
            last SWITCH;
        }

        # if ($pcno == 24) { last SWITCH; }
        # if ($pcno == 25) { last SWITCH; }
        # if (($pcno >= 28 && $pcno <= 33) || $pcno == 40 || $pcno == 42 || $pcno == 49) { last SWITCH; }
        # if ($pcno == 34 || $pcno == 36) { last SWITCH; }
        # if ($pcno == 35) { last SWITCH; }
        # if ($pcno == 37) { last SWITCH; }
        # if ($pcno == 38) { last SWITCH; }
        # if ($pcno == 39) { last SWITCH; }
        # if ($pcno == 41) { last SWITCH; }
        # if ($pcno == 43) { last SWITCH; }
        # if ($pcno == 44) { last SWITCH; }
        # if ($pcno == 45) { last SWITCH; }
        # if ($pcno == 46) { last SWITCH; }
        # if ($pcno == 47) { last SWITCH; }
        # if ($pcno == 48) { last SWITCH; }
        # if ($pcno == 50) { last SWITCH; }
        # if ($pcno == 51) { last SWITCH; }
    }

    return 0;
}

sub rbn {
    my ($self, $origin, $qrg, $call, $mode, $s, $utz, $respot) = @_;
    my $l_rbn = "$self, $origin, $qrg, $call, $mode, $s, $utz, $respot";
    my %mqtt_rbn = ('RBN' => $l_rbn);
    $json = JSON->new->canonical(1)->encode(\%mqtt_rbn);
    # $mqtt->publish("spider/raw/nodo-6", $json);
    return 0;
}

sub rbn_quality {
    my ($self, $line) = @_;
    my %mqtt_rbn = ('RBN' => $line);
    $json = JSON->new->canonical(1)->encode(\%mqtt_rbn);
    # $mqtt->publish("spider/raw/nodo-6", $json);
    return 0;
}

# sub spot { return 0; }

# sub ann { return 0; }

# sub wwv { return 0; }

# sub wcy { return 0; }

# sub userstart { return 0; }

# sub userline { return 0; }

# sub userfinish { return 0; }

sub log_msg {
    my ($self, $t, $line) = @_;

    my $node = $main::mycall;
    my @fields = split(/\^/, $line);
    $fields[2] =~ m/(\w+||\w+\-\d+)\s(\w+)/ if defined $fields[2];

    my $texto = "";

    if ($fields[1] eq "DXCommand") {
        if ($2 eq "connected") {
            $texto = "*$node*   ✅  *$1* Connect (*U*)";
            telegram($texto);
        } elsif ($2 eq "disconnected") {
            $texto = "*$node*   ❌  *$1* Disconnect (*U*)";
            telegram($texto);
        }
    } elsif ($fields[1] eq "DXProt") {
        if ($2 eq "connected") {
            $texto = "*$node*   ✅  *$1* Connect (*N*)";
            telegram($texto);
        } elsif ($2 eq "Disconnected") {
            $texto = "*$node*   ❌  *$1* Disconnect (*N*)";
            telegram($texto);
        }
    } elsif ($fields[1] eq "RBN") {
        if ($1 eq "RBN" and $6 eq "disconnecting") {
            $texto = "*$node*   ❌  *$1* Disconnect (*U*)";
            telegram($texto);
        }
    } elsif ($fields[1] eq "" and $2 eq "has too many connections") {
        $texto = "*$node*   ❎  *$1* Many connections";
        telegram($texto);
    } elsif ($fields[1] eq "cluster") {
        if ($fields[2] =~ /started/) {
            $texto = "*$node*   ⬆️  Cluster *UP*";
            telegram($texto);
        } elsif ($fields[2] =~ /ended/) {
            $texto = "*$node*   ⬇️  Cluster *DOWN*";
            telegram($texto);
        }
    } elsif ($fields[1] =~ /Message no/) {
        my @text = split(/ /, $fields[1]);
        if ($text[11] eq $main::myalias) {
            my $file = sprintf('m%06d', $text[6]);
            my $msg_file = "/spider/msg/" . $file;
            my $msg = do { local(@ARGV, $/) = $msg_file; <> };

            my @head = split(/\^/, $msg);
            my $num  = "Msg: *$text[6]*\n";
            my $from = "From: *$head[2]*\n";
            my $subj = "Subj: *$head[5]*";
            $msg =~ s/^===.+?===//s;
            $msg = "*$main::mycall*   🆕  $num$from$subj$msg";
            telegram($msg);
        }
    }

    return 0;
}

sub telegram {
    my $payload = shift;
    my $url = "https://api.telegram.org/bot$main::token/sendMessage";
    `curl -s -X POST $url -d chat_id=$main::id -d text="$payload\n" -d parse_mode="Markdown"`;
}

sub send_email {
    my ($to, $subject, $body) = @_;

    return unless $main::email_enable;
    print "📨 Intentando enviar email a $to...\n";

    my $smtp;

    if ($main::email_port == 465) {
        print "🔐 Conectando por SSL a $main::email_smtp:$main::email_port\n";
        $smtp = Net::SMTP::SSL->new(
            $main::email_smtp,
            Port    => $main::email_port,
            Hello   => 'localhost',
            Timeout => 30,
            Debug   => 1,
        );
    } else {
        print "📡 Conectando por STARTTLS a $main::email_smtp:$main::email_port\n";
        $smtp = Net::SMTP->new(
            $main::email_smtp,
            Port    => $main::email_port,
            Hello   => 'localhost',
            Timeout => 30,
            Debug   => 1,
        );

        unless ($smtp && $smtp->starttls) {
            print "❌ Error al iniciar STARTTLS\n";
            return;
        }
    }

    unless ($smtp) {
        print "❌ No se pudo conectar a $main::email_smtp:$main::email_port\n";
        return;
    }

    unless ($smtp->auth($main::email_user, $main::email_pass)) {
        print "❌ Fallo de autenticación SMTP para $main::email_user\n";
        return;
    }

    $smtp->mail($main::email_from);
    $smtp->to($to);
    $smtp->data();
    $smtp->datasend("From: $main::email_from\n");
    $smtp->datasend("To: $to\n");
    $smtp->datasend("Subject: $subject\n");
    $smtp->datasend("Content-Type: text/plain; charset=utf-8\n\n");
    $smtp->datasend("$body\n");

    my $ok = $smtp->dataend();

    if ($ok) {
        print "✅ Email enviado correctamente a $to\n";
    } else {
        print "❌ Error en el envío de datos SMTP a $to\n";
    }

    $smtp->quit;
}

1;
__END__
