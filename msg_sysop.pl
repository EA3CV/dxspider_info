#
#  msg_sysop.pl — Send message to sysop via Telegram and handle REGISTRO
#
#  Description:
#    Sends a user message to the sysop via Telegram and/or email.
#    If the subject contains "REGISTER"/"REGISTRO", the call/email/IP is stored
#    in pending_reg.txt and the user receives a confirmation email.
#
#  Usage:
#    msg_sysop <CALL> <SUBJECT> <EMAIL> <MESSAGE>
#    Example:
#      msg_sysop XX0ABC REGISTER xx0abc@example.com Requesting access
#
#  Installation:
#    Save as: /spider/local_cmd/msg_sysop.pl
#
#  Requirements:
#    - DXVars.pm with Telegram and email config
#
#  Config:
#    $use_telegram = 1;    # Enable Telegram notifications
#    $use_email    = 1;    # Enable user email confirmation
#
#  Author  : Kin EA3CV (ea3cv@cronux.net)
#  Version : 20250411 v0.4
#

use strict;
use warnings;
use Local;
use File::Path qw(make_path);
use List::Util qw(first);
use Digest::SHA qw(sha1_hex);

my $use_telegram = 1;
my $use_email    = 1;

# Editable confirmation email body (bilingual)
my $confirm_body = <<"EMAIL";
En breve recibira una respuesta.
Saludos.

You will receive a response shortly.
Regards,

$main::myname $main::myalias
EMAIL

my ($self, $line) = @_;

my @args = split /\s+/, $line;
unless (@args >= 4) {
    return (1,
        "Usage: msg_sysop <CALL> <SUBJECT> <EMAIL> <MESSAGE>",
        "Example:",
        "  msg_sysop XX0ABC REGISTER xx0abc\@example.com Requesting access"
    );
}

my ($call, $subject, $email, @message_parts) = @args;
my $message = join(' ', @message_parts);

my $real_call = $self->call // 'unknown';
my $conn = $self->conn;
my $ip = $conn->{peerhost} // 'unknown';

my @out;

if ($subject =~ /\b(register|registro)\b/i) {
    my $file = "/spider/local_data/pending_reg.txt";
    my $password = generate_password();
    my $entry = uc($call) . ",$password,$ip,$email";

    my @lines;
    my $found = 0;

    eval {
        unless (-d "/spider/local_data") {
            make_path("/spider/local_data");
            push @out, "Directory /spider/local_data created.\n";
        }

        if (-e $file) {
            open my $rfh, '<', $file or die "Cannot read $file: $!";
            while (my $line = <$rfh>) {
                chomp $line;
                if ($line =~ /^$call,/i) {
                    push @lines, $entry;
                    $found = 1;
                } else {
                    push @lines, $line;
                }
            }
            close $rfh;
        }

        push @lines, $entry unless $found;

        open my $wfh, '>', $file or die "Cannot write $file: $!";
        print $wfh "$_\n" for @lines;
        close $wfh;
    };
    if ($@) {
        push @out, "Error writing $file: $@\n";
    }

    if ($use_email) {
        eval {
            Local::send_email($email, "Recibido mensaje para el sysop de $main::mycall", $confirm_body);
        };
    }
}

# Telegram to sysop
if ($use_telegram) {
    my $payload = <<"TELEGRAM";
📡 *Message from DXSpider command:*
*Call:* $call
*Subject:* $subject
*Email:* $email
*Sent by:* $real_call ($ip)
*IP:* $ip

$message
TELEGRAM

    eval {
        Local::telegram($payload);
    };
    push @out, "Warning: Telegram send failed: $@" if $@;
}

# Email internal sysop copy
if ($use_email) {
    my $sysop_body = <<"SYSMSG";
New message via msg_sysop command:

Call: $call
Subject: $subject
Email: $email
IP: $ip
Message: $message

SYSMSG

    eval {
        Local::send_email("ea3cv\@cronux.net", "Message received from $call ($subject)", $sysop_body);
    };
}

push @out, "Message sent to sysop.";
push @out, " ";
push @out, "   Call: $call";
push @out, "Subject: $subject";
push @out, "  Email: $email";
push @out, "Message: $message\n";
push @out, " ";

return (1, @out);

sub generate_password {
    my @chars = ('A'..'Z', 'a'..'z', 0..9, qw/[] . - = % & $/);
    return join('', map { $chars[int rand @chars] } 1..8);
}
