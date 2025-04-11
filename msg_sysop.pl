#
#  msg_sysop.pl — Send message to sysop via Telegram and/or Email
#
#  Description:
#    This script allows users to send a message to the sysop via the `msg_sysop` command.
#
#    It can be used independently or as part of the automated registration/password system.
#    When the subject includes REGISTER or REGISTRO:
#      - Generates a random password
#      - Saves registration data to `/spider/local_data/pending_reg.txt`
#      - Sends a bilingual confirmation email to the user
#
#    All messages:
#      - Can be sent to the sysop via Telegram and/or Email
#      - Are logged with full details: call, subject, email, IP, and content
#
#  Usage:
#    msg_sysop <CALL> <SUBJECT> <EMAIL> <MESSAGE>
#
#    Examples:
#      msg_sysop XX0ABC REGISTER xx0abc@example.com Requesting access
#      msg_sysop XX0ABC "Feedback" xx0abc@example.com Me falla el comando connect
#
#  Configuration:
#    Configuration is managed from DXVars.pm.
#
#    Add the following block at the end of DXVars.pm before the final `1;`:
#
#    # Telegram config
#    $id = "<telegram_chat_id>";
#    $token = "<telegram_bot_token>";
#
#    # Email SMTP config
#    $email_enable = 1;                  # Enable email sending (1 = yes, 0 = no)
#    $email_from   = 'your@email.com';   # Sender address
#    $email_smtp   = 'smtp.example.com'; # SMTP server
#    $email_port   = 587;                # SMTP port (587 for STARTTLS, 465 for SSL)
#    $email_user   = 'your@email.com';   # SMTP user
#    $email_pass   = 'app-password';     # SMTP password or app token
#
#    # Telegram control (1 = send Telegram messages, 0 = do not send)
#    $use_telegram = 1;
#
#  Installation:
#    Save this script as: /spider/local_cmd/msg_sysop.pl
#
#  Related:
#    If using the full registration/password system, this script is used by:
#      - msg_sysop       : sends user feedback and registration requests
#      - auth_register   : validates a pending registration
#      - deny_register   : rejects a pending registration
#
#  Author  :  Kin EA3CV (ea3cv@cronux.net)
#
#  Version : 20250411 v0.1
#

use strict;
use warnings;
use Local;
use File::Path qw(make_path);
use List::Util qw(first);
use Digest::SHA qw(sha1_hex);

my $use_telegram = 1;

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

    # Email de confirmación al usuario
    my $body = <<"EMAIL";
En breve recibira una respuesta.
Saludos.

You will receive a response shortly.
Regards,

Kin EA3CV
EMAIL

    eval {
        Local::send_email($email, "Received message for $main::mycall for $main::mycall", $body);
    };
}

if ($use_telegram) {
    my $payload = <<"END_MSG";
📡 *Message from DXSpider $main::mycall:*
*Call:* $call
*Subject:* $subject
*Email:* $email
*Sent by:* $real_call
*IP:* $ip

$message
END_MSG

    eval {
        Local::telegram($payload);
    };
    push @out, "Warning: Telegram send failed: $@" if $@;
}

my $sysop_body = <<"BODY";
New message via msg_sysop command:

Call: $call
Subject: $subject
Email: $email
IP: $ip
Message: $message

BODY

eval {
    Local::send_email($main::email_from, "Message received from $call ($subject) in $main::mycall", $sysop_body);
};

push @out, "Message sent to sysop.";
push @out, " ";
push @out, "   Call: $call";
push @out, "Subject: $subject";
push @out, "  Email: $email";
push @out, "Message: $message\n";
push @out, " ";

return (1, @out);

sub generate_password {
    my @chars = ('A'..'Z', 'a'..'z', 0..9, qw/[] . - = % & \$/);
    return join('', map { $chars[int rand @chars] } 1..8);
}
