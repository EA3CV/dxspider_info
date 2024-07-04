#
# The system variables - those indicated will need to be changed to suit your
# circumstances (and callsign)
#
# Copyright (c) 1998-2007 - Dirk Koopman G1TLH
#
#

package main;

# this really does need to change for your system!!!!
# use CAPITAL LETTERS
$mycall = "XXXXX-3";

# your name
$myname = "";

# Your 'normal' callsign (in CAPTTAL LETTERS)
$myalias = "XXXXXX";

# Your latitude (+)ve = North (-)ve = South in degrees and decimal degrees
$mylatitude = "+40.43300000";

# Your Longtitude (+)ve = East, (-)ve = West in degrees and decimal degrees
$mylongitude = "-3.70000000";

# Your locator (USE CAPITAL LETTERS)
$mylocator = "xxxxxx";

# Your QTH (roughly)
$myqth = "xxxxx, xxxxx";

# Your e-mail address
$myemail = "xxx\@xxx.xxx";

# the country codes that my node is located in
#
# for example 'qw(EA EA8 EA9 EA0)' for Spain and all its islands.
# if you leave this blank then it will use the country code for
# your $mycall. This will suit 98% of sysops (including GB7 BTW).
#

@my_cc = qw();

# are we debugging ?
@debug = qw(chan connect cron msg progress state badword);

# are we doing xml?
$do_xml = 0;

# the SQL database DBI dsn
#$dsn = "dbi:SQLite:dbname=$root/data/dxspider.db";
#$dbuser = "";
#$dbpass = "";

# Telegram Bot by Kin EA3CV
$id = "xxxxxxxxx";
$token = "xxxxxxxxxxxxxxxxxxx";

1;
