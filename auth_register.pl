#
#  auth_register.pl — Authorize a pending registration in DXSpider
#
#  Description:
#    Activates a user from pending_reg.txt, sets the password, and marks them as registered.
#    Optionally notifies the user via email and the sysop via Telegram.
#
#  Usage:
#    From DXSpider shell:
#      auth_register <CALLSIGN>
#
#  Requirements:
#    - Entry in /spider/local_data/pending_reg.txt
#    - Email config in DXVars.pm if email notifications are enabled
#    - Telegram config in DXVars.pm if Telegram notifications are enabled
#
#  Installation:
#    Save as: /spider/local_cmd/auth_register.pl
#
#  Config:
#    $use_email    = 1;      # Enable/disable email notification to user
#    $use_telegram = 1;      # Enable/disable Telegram message to sysop
#
#  Author  : Kin EA3CV (ea3cv@cronux.net)
#  Version : 20250411 v0.3
#

use strict;
use warnings;
use DXUser;
use Local;

my $use_telegram = 1;
my $use_email    = 1;

# Editable message templates for user notification (ES + EN)
my $msg_es = <<"ES";
Se ha aceptado su solicitud de registro

Usuario: %CALL%
Password: %PASS%

Use el comando \`set/password\` para cambiar la contraseña si lo desea.
Disfrute.
ES

my $msg_en = <<"EN";
Your registration request has been approved.

User: %CALL%
Password: %PASS%

You can use the \`set/password\` command to change your password if you wish.
Enjoy.
EN

my ($self, $line) = @_;

unless ($line =~ /^\s*(\S+)/) {
    return (1, "Usage: auth_register <CALLSIGN>");
}

my $target_call = uc($1);
my $file     = "/spider/local_data/pending_reg.txt";
my $tempfile = "/spider/local_data/pending_reg.tmp";

open(my $in,  '<', $file)     or return (1, "❌ Cannot open $file: $!");
open(my $out, '>', $tempfile) or return (1, "❌ Cannot create $tempfile: $!");

my $found;
while (my $line = <$in>) {
    if ($line =~ /^($target_call),([^,]+),([^,]+),([^\s\r\n]+)/i) {
        my ($call, $pass, $ip, $email) = ($1, $2, $3, $4);
        $found = {
            call  => $call,
            pass  => $pass,
            ip    => $ip,
            email => $email,
        };
        next;
    }
    print $out $line;
}

close($in);
close($out);
rename $tempfile, $file;

unless ($found) {
    return (1, "❌ No pending registration found for $target_call.");
}

my $ref = DXUser::get_current($found->{call}) || DXUser->new($found->{call});
$ref->registered(1);
$ref->passwd($found->{pass});
$ref->put();

if ($use_email) {
    my $body = $msg_es . "\n\n" . $msg_en . "\n\n$main::myname $main::myalias";
    $body =~ s/%CALL%/$found->{call}/g;
    $body =~ s/%PASS%/$found->{pass}/g;

    Local::send_email(
        $found->{email},
        "Aceptada su solicitud de registro / Registration accepted $found->{call} at $main::mycall",
        $body
    );
}

if ($use_telegram) {
    Local::telegram("✅ Registered $found->{call} in $main::mycall");
}

return (1,
    "✔️ Registration completed for $found->{call}",
    "   Email: $found->{email}",
    "   IP:    $found->{ip}",
    "   Pass:  $found->{pass}"
);
