# File: /spider/local/Local.pm

#
# Send all incoming traffic to MQTT/JSON
# From build 431 and up
# 
# Need DXLog.pm module modified in spider/local
# Need to modify DXVars.pm to add $id & $token
#
# Modified by Kin EA3CV with the inestimable help of Dirk
#
# Kin ea3cv@cronux.net
#
# 20230306 v6.3
#

package Local;

use DXVars;
use DXDebug;
use DXUtil;
use JSON;
#
use DXLog;
#
use 5.10.1;
use Net::MQTT::Simple;
use strict;

# declare any global variables you use in here
use vars qw{$mqtt $json};

# called at initialisation time
sub init
{
        $mqtt = Net::MQTT::Simple->new("localhost:1883");
}


# called once every second
#sub process
#{
#
#}

# called just before the ending of the program
#sub finish
#{
#
#}

# called after an incoming PC line has been split up, return 0 if you want to
# continue and 1 if you wish the PC Protocol line to be ignored completely
#
# Parameters:-
# $self      - the DXChannel object
# $pcno      - the no of the PC field
# $line      - the actual incoming line with its hop count already decremented
# @field     - the spot exactly as is, split up into fields
#              $field[0] will be PC11 or PC26
sub pcprot
{
        my ($self, $pcno, $line, @field) = @_;

        # take out any switches that aren't interesting to you.
 SWITCH: {
#               if ($pcno == 10) {              # incoming talk
#                       last SWITCH;
#               }

                if ($pcno == 11 || $pcno == 26 || $pcno == 61) { # dx spot
                        my %mqtt_spot = ('SPOTS'=>$line);
                        $json = JSON->new->canonical(1)->encode( \%mqtt_spot );
                        $mqtt->publish("spider/raw/nodo-6", $json);
                        return 0;
                        last SWITCH;
                }

                if ($pcno == 12 || $pcno == 93) {               # announces
                    my %mqtt_spot = ('ANN'=>$line);
            $json = JSON->new->canonical(1)->encode( \%mqtt_spot );
#            $mqtt->publish("spider/raw/nodo-6", $json);
##          return 0;
                        last SWITCH;
                }

#               if ($pcno == 13) {
#                       last SWITCH;
#               }
#               if ($pcno == 14) {
#                       last SWITCH;
#               }
#               if ($pcno == 15) {
#                       last SWITCH;
#               }

#               if ($pcno == 16) {              # add a user
#                       last SWITCH;
#               }

#               if ($pcno == 17) {              # remove a user
#                       last SWITCH;
#               }

#               if ($pcno == 18) {              # link request
#                       last SWITCH;
#               }

#               if ($pcno == 19) {              # incoming cluster list
#                       last SWITCH;
#               }

#               if ($pcno == 20) {              # send local configuration
#                       last SWITCH;
#               }

#               if ($pcno == 21) {              # delete a cluster from the list
#                       last SWITCH;
#               }

#               if ($pcno == 22) {
#                       last SWITCH;
#               }

                if ($pcno == 23 || $pcno == 27) { # WWV info
            my %mqtt_spot = ('WWV'=>$line);
            $json = JSON->new->canonical(1)->encode( \%mqtt_spot );
#            $mqtt->publish("spider/raw/nodo-6", $json);
##          return 0;
                        last SWITCH;
                }

        if ($pcno == 73) { # WCY info
            my %mqtt_spot = ('WCY'=>$line);
            $json = JSON->new->canonical(1)->encode( \%mqtt_spot );
#            $mqtt->publish("spider/raw/nodo-6", $json);
##          return 0;
            last SWITCH;
        }

#               if ($pcno == 24) {              # set here status
#                       last SWITCH;
#               }

#               if ($pcno == 25) {      # merge request
#                       last SWITCH;
#               }

#               if (($pcno >= 28 && $pcno <= 33) || $pcno == 40 || $pcno == 42 || $pcno == 49) { # mail/file handling
#                       last SWITCH;
#               }

#               if ($pcno == 34 || $pcno == 36) { # remote commands (incoming)
#                       last SWITCH;
#               }

#               if ($pcno == 35) {              # remote command replies
#                       last SWITCH;
#               }

#               if ($pcno == 37) {
#                       last SWITCH;
#               }

#               if ($pcno == 38) {              # node connected list from neighbour
#                       last SWITCH;
#               }

#               if ($pcno == 39) {              # incoming disconnect
#                       last SWITCH;
#               }

#               if ($pcno == 41) {              # user info
#                       last SWITCH;
#               }
#               if ($pcno == 43) {
#                       last SWITCH;
#               }
#               if ($pcno == 44) {
#                       last SWITCH;
#               }
#               if ($pcno == 45) {
#                       last SWITCH;
#               }
#               if ($pcno == 46) {
#                       last SWITCH;
#               }
#               if ($pcno == 47) {
#                       last SWITCH;
#               }
#               if ($pcno == 48) {
#                       last SWITCH;
#               }

#               if ($pcno == 50) {              # keep alive/user list
#                       last SWITCH;
#               }

#               if ($pcno == 51) {              # incoming ping requests/answers
#                       last SWITCH;
#               }
        }
        return 0;
}

# called after the spot has been stored but before it is broadcast,
# you can do funky routing here that is non-standard. 0 carries on
# after this, 1 stops dead and no routing is done (this could mean
# that YOU have done some routing or other instead
#
# Parameters:-
# $self      - the DXChannel object
# $freq      - frequency
# $spotted   - the spotted callsign
# $d         - the date in unix time format
# $text      - the text of the spot
# $spotter   - who spotted it
# $orignode  - the originating node
#
#sub spot
#{
#       my ($self, $freq, $spotted, $d, $text, $spotter, $orignode) = @_;
#
#       my %redis_spot = ('spotter'=>$spotter, 'dx'=>$spotted, 'frequency'=>$freq, 'timestamp'=>$d,
#                        'comment'=>$text, 'orignode'=>$orignode);
#
#       my $json = encode_json \%redis_spot;
#
#       $redis->publish("dxspider_spot", $json);
#       return 0;
#}

# called after the announce has been stored but before it is broadcast,
# you can do funky routing here that is non-standard. 0 carries on
# after this, 1 stops dead and no routing is done (this could mean
# that YOU have done some routing or other instead
#
# Parameters:-
# $self      - the DXChannel object
# $line      - the input PC12 line
# $announcer - the call that announced this
# $via       - the destination * = everywhere, callsign - just to that node
# $text      - the text of the chat
# $flag      - ' ' - normal announce, * - SYSOP, else CHAT group
# $origin    - originating node
# $wx        - 0 - normal, 1 - WX
#sub ann
#{
#        return 0;
#}


# called after the wwv has been stored but before it is broadcast,
# you can do funky routing here that is non-standard. 0 carries on
# after this, 1 stops dead and no routing is done (this could mean
# that YOU have done some routing or other instead
#
# Parameters:-
# $self      - the DXChannel object
# The rest the same as for Geomag::update
#sub wwv
#{
#       return 0;
#}

# same for wcy broadcasts
#sub wcy
#{
#       return 0;
#}

# no idea what or when these are called yet
#sub userstart
#{
#       return 0;
#}

#sub userline
#{
#       return 0;
#}

#sub userfinish
#{
#       return 0;
#}

sub rbn
{
       my ($self, $origin, $qrg, $call, $mode, $s, $utz, $respot) = @_;

       my $l_rbn = "$self, $origin, $qrg, $call, $mode, $s, $utz, $respot";
       my %mqtt_rbn = ('RBN'=>$l_rbn);
       $json = JSON->new->canonical(1)->encode( \%mqtt_rbn );
#       $mqtt->publish("spider/raw/nodo-6", $json);
       return 0;
}

sub rbn_quality
{
       my ($self, $line) = @_;

       my %mqtt_rbn = ('RBN'=>$line);
       $json = JSON->new->canonical(1)->encode( \%mqtt_rbn );
#       $mqtt->publish("spider/raw/nodo-6", $json);
       return 0;
}

# Log info
sub log_msg
{
        my ($self, $t, $line) = @_;

        my $node = $main::mycall;
        my @fields = split(/\^/, $line);

        $fields[2] =~ m/(\w+||\w+\-\d+)\s(\w+)/ if defined $fields[2];
        my $texto = "";

        # 1641110665^DXCommand^SK0MMR connected from 216.93.248.68
        # 1643657664^RBN^RBN: no input from SK0MMR, disconnecting
        # 1672531877^DXProt^EA2CW-2 Disconnected
        # 1672533001^DXProt^EA2CW-2 connected from 44.68.10.169
        # 1606290021^^OE3GCU has too many connections (3) at EA4URE-2,EA2CW-2,N6WS-6 - disconnected

        # Users - connected/disconnected
	my $modo = 'event';  # Puede ser 'event' or 'summary' 

	if ($fields[1] eq "DXCommand") {
		if ($2 eq "connected") {
		        $texto = "*$node*   ✅  *$1* Connect \(*U*\)";
        		if ($modo eq 'event') {
		            telegram($texto);  # Enviar mensaje por cada evento
		        } else {
		            update_count($1, 'connected', $node);  # Actualizar contador para resumen
		        }
		} elsif ($2 eq "disconnected") {
		        $texto = "*$node*   ❌  *$1* Disconnect \(*U*\)";
		        if ($modo eq 'event') {
				telegram($texto);  # Enviar mensaje por cada evento
		        } else {
				update_count($1, 'disconnected', $node);  # Actualizar contador para resumen
		        }
		}

        # Nodes - connected/disconnected
        } elsif ($fields[1] eq "DXProt") {
                if ($2 eq "connected") {
                        $texto = "*$node*   ✅  *$1* Connect \(*N*\)";
                        telegram($texto);

                } elsif ($2 eq "Disconnected") {
                        $texto = "*$node*   ❌  *$1* Disconnect \(*N*\)";
                        telegram($texto);
                }

        # RBN - disconnected
                } elsif ($fields[1] eq "RBN") {
                if ($1 eq "RBN" and $6 eq "disconnecting") {
                        $texto = "*$node*   ❌  *$1* Disconnect \(*U*\)";
                        telegram($texto);
                }

        # Has too many connections
        } elsif ($fields[1] eq "" and $2 eq "has too many connections") {
                $texto = "*$node*   ❎  *$1* Many connections";
                telegram($texto);

        # Cluster - up/down
        } elsif ($fields[1] eq "cluster") {
                if ($fields[2] =~ /started/) {
                        $texto = "*$node*   ⬆️  Cluster *UP*";
                        telegram($texto);

                } elsif ($fields[2] =~ /ended/) {
                        $texto = "*$node*   ⬇️  Cluster *DOWN*";
                        telegram($texto);
                }

	# SP Messages
        } elsif ($fields[1] =~ /Message no/) {
		my @text = split(/ /, $fields[1]);
		if ($text[11] eq $main::myalias) {
			my $file = sprintf ('m%06d', $text[6]);
			my $msg_file = "/spider/msg/".$file;
			my $msg = do{local(@ARGV,$/)=$msg_file;<>};

			my @head = split(/\^/, $msg);
                        my $num = "Msg: *$text[6]*\n";
			my $from = "From: *$head[2]*\n";
			my $subj = "Subj: *$head[5]*";
			$msg =~ s/^===.+?===//s;
			$msg = "*$main::mycall*   🆕  $num" . $from . $subj . $msg;
			telegram($msg);
		}
        }

        return 0;
}

# Definir un hash para almacenar el recuento de conexiones/desconexiones de usuario
my %count;
# Definir una variable para almacenar la hora actual en formato Unix
my $now = time();

# Función para actualizar el hash de recuento de conexiones/desconexiones
sub update_count {
	my ($user, $action, $node) = @_;
	# Obtener la hora actual en formato Unix
	my $timestamp = time();

	# Si la hora actual es diferente de la hora almacenada en $now, reiniciar el hash y actualizar la hora
	if (int($timestamp/3600) != int($now/3600)) {
		%count = ();
		$now = $timestamp;
	}
	# Incrementar el contador correspondiente en el hash
	$count{$user}{$action}++;

	# Si el umbral de 10 conexiones/desconexiones se supera en la última hora, enviar un informe por Telegram
	if ($count{$user}{$action} >= 10) {
		my $texto = "*$node*  🔟 *$user* Conn/Disconn \(*U*\)";
		telegram($texto);
		# Reiniciar el contador correspondiente en el hash
		$count{$user}{connected} = 0;
		$count{$user}{disconnected} = 0;
	}
}

sub telegram
{
        my $payload = shift;

        my $url = "https://api.telegram.org/bot$main::token/sendMessage";
        `curl -s -X POST $url -d chat_id=$main::id -d text="$payload\n" -d parse_mode="Markdown"`;
}

1;
__END__
