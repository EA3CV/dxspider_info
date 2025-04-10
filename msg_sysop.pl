#
#  msg_sysop.pl — Send message to sysop via Telegram
#
#  Description:
#    Allows users connected to DXSpider to send a formatted message directly
#    to the sysop via Telegram. Useful for registration requests, problem reports,
#    or general communication.
#
#    The message includes:
#      - Call, Subject, Email, and Message entered by the user
#      - The call and IP of the user executing the command
#
#  Usage:
#    From DXSpider shell (as a self command):
#      msg_sysop <CALL> <SUBJECT> <EMAIL> <MESSAGE>
#
#    Examples:
#      msg_sysop XX0ABC REGISTER user@example.com Please register my callsign
#      msg_sysop XX0ABC PROBLEM user@example.com Password doesn't work
#      msg_sysop XX0ABC-1 INFO user@example.com Just saying hello
#
#  Installation:
#    Save as: /spider/local_cmd/msg_sysop.pl
#
#  Requirements:
#    - The file Local.pm must exist in: /spider/local/Local.pm
#      If not, copy it from the default DXSpider location:
#        cp /spider/perl/Local.pm /spider/local/
#
#    - Telegram bot credentials must be added to: /spider/local/DXVars.pm
#      Place the following lines at the end of the file, but before the final `1;`:
#
#        # Telegram Bot
#        $id = "1234567890";
#        $token = "8282824455:SDSDSS6HYHYG07678SDS9VCB009VV";
#
#        (note that given id and token variable values are only examples)
#
#    - Restart the node for changes to take effect:
#        shutdown
#
#  Author  : Kin EA3CV (ea3cv@cronux.net)
#  Version : 20250408 v0.0
#
#  Note:
#    If no arguments are provided, usage instructions will be shown.
#

use strict;
use warnings;
use Local;

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

my $payload = <<"END_MSG";
📡 *Message from DXSpider command:*
*Call:* $call
*Subject:* $subject
*Email:* $email
*Sent by:* $real_call ($ip)
*IP:* $ip

$message
END_MSG

# Enviar mensaje por Telegram
Local::telegram($payload);

# Respuesta al usuario
my @out = (
    "Message sent to sysop via Telegram.\n",
    "   Call: $call",
    "Subject: $subject",
    "  Email: $email",
    "Comment: $message\n"
);

return (1, @out);
