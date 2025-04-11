#
#  deny_register.pl — Deny registration request and notify user
#
#  Description:
#    This script removes a pending registration request and notifies the user by email
#    and optionally via Telegram.
#
#  Usage:
#    deny_reg <CALL>
#
#  This script is used as part of the registration/password system.
#
#  Requirements:
#    - DXVars config with Telegram and Email settings
#    - `pending_reg.txt` file with pending entries
#
#  Author  : Kin EA3CV (ea3cv@cronux.net)
#  Version : 20250411 v0.0
#

use strict;
use warnings;
use DXUser;
use Local;

my $use_telegram = 1;
my $email_enable = 1;

my ($self, $line) = @_;

unless ($line =~ /^\s*(\S+)/) {
    return (1, "Usage: deny_reg <CALL>");
}

my $target_call = uc($1);
my $file = "/spider/local_data/pending_reg.txt";
my $tempfile = "/spider/local_data/pending_reg.tmp";

open(my $in, '<', $file) or return (1, "❌ Cannot open $file: $!");
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
    return (1, "❌ No pending request found for $target_call.");
}

# Email to user (bilingual)
if ($email_enable) {
    my $msg = <<"EMAIL";
Lamentamos informarle que su solicitud de acceso para $found->{call} ha sido denegada en $main:mycall.

No cumple con los criterios requeridos.
Puede intentarlo más adelante si lo desea.

We regret to inform you that your access request for $found->{call} has been denied on $main:mycall.

It does not meet the required criteria.
You may try again later if you wish.

$main::myname $main::myalias
EMAIL

    eval {
        Local::send_email($found->{email}, "Solicitud de acceso denegada / Access request denied", $msg);
    };
}

# Telegram to sysop
if ($use_telegram) {
    eval {
        Local::telegram("❌ Registration denied for $found->{call} in $main::mycall");
    };
}

return (1,
    "✔️ Registration denied for $found->{call}",
    "   Email: $found->{email}",
    "   IP:    $found->{ip}"
);
