#
# unset/regpass <callsign>
#
# Unify the unregistration + unpassword process in a single command
#
# It is located in /spider/local_cmd/unset/regpass.pl
# 
# Only for the Mojo branch
#
# Kin EA3CV, ea3cv@cronux.net
#
# 20230306 v0.0 
#

my ($self, $line) = @_;
my @args = split /\s+/, $line, 2;

my @out;

push @out, DXCommandmode::run_cmd($self, "unset/password $args[0]");
push @out, DXCommandmode::run_cmd($self, "unset/register $args[0]");

return (1, @out);
