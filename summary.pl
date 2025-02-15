#
# DXSpider data summary
#
# Use: summary (sum)
#
# Copy in /spider/local_cmd/summary.pl
#
# Kin EA3CV, ea3cv@cronux.net
#
# 20250215 v0.2
#

use strict;
use warnings;
use Cwd 'abs_path';

my $self = shift;
return 1 unless $self->priv >= 5;

my @out;

push @out, "-" x 80;
push @out, sprintf "%22s %-10s        %8s %-10s", "Node:", $main::mycall, "Sysop:", $main::myalias;
push @out, "-" x 80;
push @out, sprintf "%10s%-8s %-6s        %-4s %-7s        %-7s %-10s",
   "", "Version:", $main::version,
    "Build:", $main::build,
    "Uptime:", main::uptime();
push @out, "-" x 80, " ";

# Obtener información del sistema
my $distro       = qx(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"');
my $perl_version = $^V;
my $hostname     = qx(hostname);
my $current_path = abs_path(".");
my $disk_usage   = qx(df -h "$current_path" | awk 'NR==2 {print \$5}');
chomp($_) for ($distro, $hostname, $disk_usage);

push @out, "------------------------------------ Host --------------------------------------";
push @out, sprintf "%22s %-20s", "Host:", $hostname;
push @out, sprintf "%22s %-10s        %8s %-10s", "Distro:", $distro, "Perl:", $perl_version;
push @out, sprintf "%22s %-10s             %8s %-10s", "Path:", $current_path, "Disk usage:", $disk_usage;
push @out, " ";

# Información de red
push @out, "---------------------------------- Public IP -----------------------------------";
push @out, sprintf "%22s %-20s", "Public IPv4:", $main::localhost_alias_ipv4;
push @out, sprintf "%22s %-20s", "Public IPv6:", $main::localhost_alias_ipv6;
push @out, " ";

# Puertos de escucha
push @out, "--------------------------------- Listen Port ----------------------------------";
if (@main::listen) {
    push @out, map { sprintf "Listen Port: ['%s', %d]", $_->[0], $_->[1] } @main::listen;
} else {
    push @out, "Error: No hay datos en \@main::listen";
}
push @out, " ";

# IP local
push @out, "----------------------------------- Local IP -----------------------------------";
push @out, sprintf "%22s %-20s", "Local IP:", join(", ", @main::localhost_names);
push @out, " ";

# Depuración
push @out, "------------------------------------ Debug -------------------------------------";
push @out, sprintf "%22s %-20s", "Debug ON:", join(", ", @main::debug);
push @out, " ";

# Seguridad
push @out, "---------------------------------- Security ------------------------------------";
push @out, sprintf "%22s %-20s", "             Register:    \$main::reqreg     ", $main::reqreg;
push @out, sprintf "%22s %-20s", "             Password:    \$main::passwdreq  ", $main::passwdreq // 0;
push @out, " ";

# Variables PC92
push @out, "---------------------------------- PC92 Vars -----------------------------------";
push @out, sprintf "%22s %-10s", "             PC92 A/D:    \$DXProt::pc92_ad_enable      ", $DXProt::pc92_ad_enable;
push @out, sprintf "%22s %-10s", "          PC92 IPaddr:    \$DXProt::pc92c_ipaddr_enable ", $DXProt::pc92c_ipaddr_enable;
push @out, " ";

# Variables de comandos
push @out, "---------------------------------- CMD Vars ------------------------------------";
push @out, sprintf "%22s %-20s", "          Max CMD Bad:    \$DXCommandmode::maxbadcount ", $DXCommandmode::maxbadcount;
push @out, " ";

# Total de peers y usuarios
push @out, "----------------------------- Total Peers/Users --------------------------------";
push @out, sprintf "%22s %-10s        %8s %-10s", "Peers Nodes:", scalar DXChannel::get_all_nodes(), "Total Users:", scalar DXChannel::get_all_users();
push @out, " ";

# Spots
push @out, "--------------------------------- Total Spots ----------------------------------";
push @out, sprintf "%22s %-10s        %8s %-10s", "Total Spots:", $Spot::totalspots, "Total S. HF:", $Spot::hfspots;
push @out, " ";

# Consola
push @out, "----------------------------------- Console ------------------------------------";
push @out, sprintf "%22s %-10s        %8s %-10s", "IP Addr:", $main::clusteraddr, "Port:", $main::clusterport;
push @out, " ";

# Variables de spots
push @out, "--------------------------------- Spots Vars -----------------------------------";
push @out, sprintf "%22s %-10s", "       Slot Time  (s):    \$Spot::timegranularity ", $Spot::timegranularity;
push @out, sprintf "%22s %-10s", "       Slot QRG (kHz):    \$Spot::qrggranularity  ", $Spot::qrggranularity;
push @out, sprintf "%22s %-10s", "       Dupe Page  (s):    \$Spot::dupage          ", $Spot::dupage;
push @out, sprintf "%22s %-10s", "       Autospot (kHz):    \$Spot::minselfspotqrg  ", $Spot::minselfspotqrg;
push @out, " ";

# Variables RBN
push @out, "---------------------------------- RBN Vars ------------------------------------";
push @out, sprintf "%22s %-10s", "               Byte Q:    \$RBN::minqual    ", $RBN::minqual;
push @out, sprintf "%22s %-10s", "      Respot time (s):    \$RBN::respottime ", $RBN::respottime;
push @out, " ";

# Filtros de nodo
my $call = "node_default";
push @out, "-------------------------------- Node Filters ----------------------------------";
for my $sort (qw(route ann spots wcy wwv rbn)) {
    for my $flag (1, 0) {
        if (my $ref = Filter::read_in($sort, $call, $flag)) {
            push @out, $ref->print($call, $sort, $flag ? "input" : "");
            push @out, " ";
        }
    }
}

# Directorios a inspeccionar
my $dir_local = "/spider/local";
my $dir_connect = "/spider/connect";

# Listar archivos .pm en spider/local/ (excluyendo archivos ocultos)
push @out, " ";
push @out, "---------------------------------- local dir -----------------------------------";
if (-d $dir_local) {
    opendir(my $dh, $dir_local) or die "No se puede abrir $dir_local: $!\n";
    push @out, sprintf("Modules in %s:", $dir_local);
    my @files = grep { /^[^\.].*\.pm$/ } readdir($dh); # Excluir archivos ocultos y filtrar .pm
    closedir($dh);

    @files = sort @files;  # Ordenar alfabéticamente
    push @out, map { sprintf("%27s%s", "", $_) } @files;  # Desplazamiento de 10 espacios
} else {
    push @out, sprintf("El directorio %s no existe.", $dir_local);
}

# Listar todos los archivos en spider/connect/ (excluyendo archivos ocultos)
push @out, " ";
push @out, "--------------------------------- connect dir ----------------------------------";
if (-d $dir_connect) {
    opendir(my $dh, $dir_connect) or die "No se puede abrir $dir_connect: $!\n";
    push @out, sprintf("Connection files in %s:", $dir_connect);
    my @files = grep { !/^\./ } readdir($dh); # Excluir archivos ocultos
    closedir($dh);

    @files = sort @files;  # Ordenar alfabéticamente
    push @out, map { sprintf("%38s%s", "", $_) } @files;  # Desplazamiento de 10 espacios
} else {
    push @out, sprintf("El directorio %s no existe.", $dir_connect);
}

# Conexiones de nodos detalladas

my $dxchan;
my $tnow = time();
push @out, " ";
push @out, "---------------------------------- Node List -----------------------------------";
push @out, "Node      R P  Type  IP Address      Port   Dir.  State   Cnum  Connection Time";
push @out, "--------  - -  ----  --------------- -----  ----  ------  ----  ---------------";

foreach $dxchan ( sort {$a->call cmp $b->call} DXChannel::get_all ) {
    my $call = $dxchan->call();
    # Ignorar si el call es igual a $main::mycall
    next if defined $main::mycall && $call eq $main::mycall;
    my $t = cldatetime($dxchan->startt);
    my $type = $dxchan->is_node ? "NODE" : "USER";
    my $sort = "    ";
    if ($dxchan->is_node) {
        $sort = "DXSP" if $dxchan->is_spider;
        $sort = "CLX " if $dxchan->is_clx;
        $sort = "DXNT" if $dxchan->is_dxnet;
        $sort = "AR-C" if $dxchan->is_arcluster;
        $sort = "AK1A" if $dxchan->is_ak1a;
        $sort = "CCCL" if $dxchan->is_ccluster;
    }

    my ($conn, $state) = ($dxchan->conn, $dxchan->state);
    my ($ip, $port, $dir, $cnum, $reg) = @{$conn}{qw(peerhost peerport sort cnum csort)};

    $dir = $dir eq "Incoming" ? "IN" : $dir eq "Outgoing" ? "OUT" : $dir;

    my $reg = (DXUser::get_current($call) // {})->{registered} eq "1" ? "R" : "";
    my $pass = (DXUser::get_current($call) // {})->{passwd} ? "P" : "";


    my $delta = $tnow - $dxchan->startt;
    my $time_on = sprintf("%3d d%3d h %3d m", int($delta/(24*60*60)), int(($delta/(60*60))%24), int(($delta/60)%60));

    if ($type eq "NODE") {
        push @out, sprintf "%-9s %1s %1s  %-4s  %-15s %-6s %-5s %-6s %5s $time_on",
            $call, $reg, $pass, $sort, $ip, $port, $dir, $state, $cnum;
        }
}

# Conexiones de usuarios detalladas
push @out, " ";
push @out, "---------------------------------- Users List ----------------------------------";
push @out, "User      R P  Type  IP Address      Port   Dir.  State   Cnum  Connection Time";
push @out, "--------  - -  ----  --------------- -----  ----  ------  ----  ---------------";

foreach $dxchan ( sort {$a->call cmp $b->call} DXChannel::get_all ) {
    my $call = $dxchan->call();
    # Ignorar si el call es igual a $main::mycall
    next if defined $main::mycall && $call eq $main::mycall;
    my $t = cldatetime($dxchan->startt);
    my $type = $dxchan->is_node ? "NODE" : "USER";
    my $sort = "    ";
    if (!$dxchan->is_node || $dxchan->is_rbn) {
        $sort = "LOCL" if $dxchan->conn->isa('IntMsg');
        $sort = "WEB " if $dxchan->is_web;
        $sort = "EXT " if $dxchan->conn->isa('ExtMsg');
        $sort = "RBN " if $dxchan->is_rbn;
    }

    my ($conn, $state) = ($dxchan->conn, $dxchan->state);
    my ($ip, $port, $dir, $cnum, $reg) = @{$conn}{qw(peerhost peerport sort cnum csort)};

    $dir = $dir eq "Incoming" ? "IN" : $dir eq "Outgoing" ? "OUT" : $dir;

    my $reg = (DXUser::get_current($call) // {})->{registered} eq "1" ? "R" : "";
    my $pass = (DXUser::get_current($call) // {})->{passwd} ? "P" : "";


    my $delta = $tnow - $dxchan->startt;
    my $time_on = sprintf("%3d d%3d h %3d m", int($delta/(24*60*60)), int(($delta/(60*60))%24), int(($delta/60)%60));

    if ($type eq "USER") {
        push @out, sprintf "%-9s %1s %1s  %-4s  %-15s %-6s %-5s %-6s %5s $time_on",
            $call, $reg, $pass, $sort, $ip, $port, $dir, $state, $cnum;
        }
}

# Peers

my $dxchan;
push @out, " ";
push @out, "-------------------------------- Partners List ---------------------------------";
push @out, "Node      Type  Version  Build  R  P  Priv  Badnode  Isolate";
push @out, "--------  ----  -------  -----  -  -  ----  -------  -------";

foreach $dxchan ( sort {$a->call cmp $b->call} DXChannel::get_all ) {
    my $call = $dxchan->call();
    # Ignorar si el call es igual a $main::mycall
    next if defined $main::mycall && $call eq $main::mycall;
    my $t = cldatetime($dxchan->startt);
    my $type = $dxchan->is_node ? "NODE" : "USER";
    my $sort = "    ";
    if ($dxchan->is_node) {
        $sort = "DXSP" if $dxchan->is_spider;
        $sort = "CLX " if $dxchan->is_clx;
        $sort = "DXNT" if $dxchan->is_dxnet;
        $sort = "AR-C" if $dxchan->is_arcluster;
        $sort = "AK1A" if $dxchan->is_ak1a;
        $sort = "CCCL" if $dxchan->is_ccluster;
    }

    my ($conn, $state) = ($dxchan->conn, $dxchan->state);
    my ($ip, $port, $dir, $cnum, $reg) = @{$conn}{qw(peerhost peerport sort cnum csort)};

    my $priv = (DXUser::get_current($call) // {})->{priv};
#    my $lock = (DXUser::get_current($call) // {})->{lockout} eq "1" ? "Y" : "";
    my $version = (DXUser::get_current($call) // {})->{version};
    my $build = (DXUser::get_current($call) // {})->{build};
    my $badnode = ($DXProt::badnode->in($call)) eq "1" ? "Y" : "";
    my $reg = (DXUser::get_current($call) // {})->{registered} eq "1" ? "R" : "";
    my $pass = (DXUser::get_current($call) // {})->{passwd} ? "P" : "";
    my $isolate = (DXUser::get_current($call) // {})->{isolate} ? "Y" : "";

if ($type eq "NODE") {
    push @out, sprintf "%-9s %-4s %7s %6s %3s %2s %4s %6s   %6s",
                $call, $sort, $version, $build, $reg, $pass, $priv, $badnode, $isolate;
}

}
push @out, " ";

return (1, @out);
