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
$mycall = "Q0QQQ-2";
$mycall_pass = "xxxxxxx";
$mycall_reg = "1";
$mycall_K = "1";

# your name
$myname = "Kin";

# Your 'normal' callsign (in CAPTTAL LETTERS)
$myalias = "Q0QQQ";
$myalias_pass = "zzzzzzzz";
$myalias_reg = "1";
$myalias_K = "0";

# Your latitude (+)ve = North (-)ve = South in degrees and decimal degrees
$mylatitude = "+40.43300000";

# Your Longtitude (+)ve = East, (-)ve = West in degrees and decimal degrees
$mylongitude = "-3.70000000";

# Your locator (USE CAPITAL LETTERS)
$mylocator = "AA00BB";

# Your QTH (roughly)
$myqth = "Barcelona, Spain";

# Your e-mail address
$myemail = "sysop\@test.info";

# the country codes that my node is located in
#
# for example 'qw(EA EA8 EA9 EA0)' for Spain and all its islands.
# if you leave this blank then it will use the country code for
# your $mycall. This will suit 98% of sysops (including GB7 BTW).
#

@my_cc = qw();

# are we debugging ?
@debug = qw(chan connect cron msg progress state);

# are we doing xml?
$do_xml = 0;

# For DB users.v3j/MySQL
$db_backend = 'mysql';  # 'dbfile' or 'mysql'

# MySQL/MariaDB specific configuration for the users/nodes database
$mysql_db      = "dxspider";
$mysql_user    = "yout_user";
$mysql_pass    = "your_pass";
$mysql_host    = "dx-mariadb";
$mysql_table   = "users_new";
$mysql_bads    = "bads";

# the SQL database DBI dsn. Spots
#$dsn = "dbi:SQLite:dbname=$root/data/dxspider.db";
#$dbuser = "";
#$dbpass = "";

1;
