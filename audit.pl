#
# DXSpider audit command
#
# Scoring note:
#   This version only reports confirmed DXSpider runtime variables.
#   No conceptual fields such as node_public_ip_ok or spotter_public_ip_ok
#   are generated here. Those must not be scored until they are collected
#   from real DXSpider data.
#
# Use:
#   audit
#   audit json
#   audit send
#   audit rekey
#
# Copy in /spider/local_cmd/audit.pl
#
#
# EA3CV Kin <ea3cv@cronux.net>
#
# 20260614 v1.8
#

use strict;
use warnings;
use JSON::PP;
use POSIX qw(strftime);
use File::Basename;
use Digest::SHA qw(sha256_hex);

my $self = shift;
my $mode = shift || "";

return 1 unless $self->priv >= 9;

my $AUDIT_SERVER = "http://51.210.246.141:9090";

my $AUDIT_DIR    = "/spider/local_data";
my $KEY_FILE     = "$AUDIT_DIR/audit.key";
my $PUB_FILE     = "$AUDIT_DIR/audit.pub";
my $CONF_FILE    = "$AUDIT_DIR/audit.conf";
my $STATUS_FILE  = "$AUDIT_DIR/audit.status";
my $DEBUG_FILE   = "$AUDIT_DIR/audit.debug";

my %rbn_exception = map { $_ => 1 } qw(SK0MMR SK1MMR);

sub jbool {
    return $_[0] ? JSON::PP::true : JSON::PP::false;
}

sub yn {
    return $_[0] ? "Y" : "N";
}

sub utc {
    my $t = shift || time;
    return strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($t));
}

sub audit_log {
    my $msg = shift;
    if (open my $fh, ">>", $DEBUG_FILE) {
        print $fh utc(time) . " audit: $msg\n";
        close $fh;
    }
}

sub read_file {
    my $file = shift;
    return undef unless -r $file;
    local $/;
    open my $fh, "<", $file or return undef;
    my $txt = <$fh>;
    close $fh;
    return $txt;
}

sub write_file {
    my ($file, $txt, $mode) = @_;
    open my $fh, ">", $file or return 0;
    print $fh $txt;
    close $fh;
    chmod $mode, $file if defined $mode;
    return 1;
}

sub write_json_file {
    my ($file, $obj, $mode) = @_;
    my $txt = JSON::PP->new->canonical(1)->pretty(1)->encode($obj);
    return write_file($file, $txt, $mode);
}

sub age_text {
    my $seconds = shift || 0;
    return sprintf "%dd %02dh %02dm",
        int($seconds / 86400),
        int(($seconds / 3600) % 24),
        int(($seconds / 60) % 60);
}

sub file_entries {
    my $file = shift;
    return 0 unless -r $file;

    open my $fh, "<", $file or return 0;
    my $count = 0;

    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq "";
        next if $line =~ /^#/;

        if ($file =~ /badword/i) {
            $count++;
            next;
        }

        my $matched = 0;
        while ($line =~ /['"]([^'"]+)['"]\s*=>/g) {
            my $k = $1;
            next if $k eq "name";
            $matched = 1;
            $count++;
        }

        $count++ if !$matched && $line !~ /=>/;
    }

    close $fh;
    return $count;
}

sub file_info {
    my $file = shift;

    return {
        exists   => jbool(0),
        path     => $file,
        name     => defined $file ? basename($file) : undef,
        age_days => undef,
        mtime    => undef,
        size     => undef,
        entries  => 0,
    } unless defined $file && -e $file;

    my @st = stat($file);

    return {
        exists   => jbool(1),
        path     => $file,
        name     => basename($file),
        age_days => int((time - $st[9]) / 86400),
        mtime    => utc($st[9]),
        size     => $st[7],
        entries  => file_entries($file),
    };
}

sub newest_file {
    my @files = @_;
    return undef unless @files;
    @files = sort { (stat($b))[9] <=> (stat($a))[9] } @files;
    return $files[0];
}

sub collect_badlists {
    my @dirs = qw(/spider/local_data /spider/data);

    my %patterns = (
        baddx      => "baddx*",
        badip      => "badip*",
        badnode    => "badnode*",
        badspotter => "badspotter*",
        badword    => "badword*",
    );

    my %out;

    for my $name (sort keys %patterns) {
        my @files;

        for my $dir (@dirs) {
            next unless -d $dir;
            push @files, glob("$dir/$patterns{$name}");
        }

        @files = grep { -f $_ } @files;
        my $newest = newest_file(@files);

        $out{$name} = {
            newest => $newest ? file_info($newest) : file_info("/spider/local_data/$name"),
            all    => [ map { file_info($_) } sort @files ],
        };
    }

    return \%out;
}

sub short_node_type {
    my $dxchan = shift;

    return "DXSP" if $dxchan->is_spider;
    return "CLX " if $dxchan->is_clx;
    return "DXNT" if $dxchan->is_dxnet;
    return "AR-C" if $dxchan->is_arcluster;
    return "AK1A" if $dxchan->is_ak1a;
    return "CCCL" if $dxchan->is_ccluster;
    return "RBN " if $dxchan->is_rbn;
    return "NODE" if $dxchan->is_node;
    return "USER";
}

sub node_type {
    my $dxchan = shift;

    return "DXSpider"   if $dxchan->is_spider;
    return "CLX"        if $dxchan->is_clx;
    return "DXNet"      if $dxchan->is_dxnet;
    return "AR-Cluster" if $dxchan->is_arcluster;
    return "AK1A"       if $dxchan->is_ak1a;
    return "CC Cluster" if $dxchan->is_ccluster;
    return "RBN"        if $dxchan->is_rbn;
    return "Node"       if $dxchan->is_node;
    return "User";
}

sub safe_user_info {
    my $call = shift;
    my $ref = DXUser::get_current(uc $call) || {};

    return {
        registered       => jbool($ref->{registered} && $ref->{registered} eq "1"),
        password_defined => jbool($ref->{passwd}),
        priv             => $ref->{priv},
        isolate          => jbool($ref->{isolate}),
    };
}

sub collect_connections {
    my @neighbours;
    my @rbn_nodes;
    my @users;

    foreach my $dxchan (sort { $a->call cmp $b->call } DXChannel::get_all()) {
        my $call = uc $dxchan->call;
        next if defined $main::mycall && $call eq uc($main::mycall);

        my $user = safe_user_info($call);
        my $conn = $dxchan->conn;

        my ($dir, $cnum) = ("", "");

        if ($conn) {
            $dir  = $conn->{sort};
            $cnum = $conn->{cnum};
        }

        $dir = $dir eq "Incoming" ? "IN" : $dir eq "Outgoing" ? "OUT" : $dir;

        my $route = Route::Node::get($call) || {};

        my $item = {
            call             => $call,
            type             => node_type($dxchan),
            short_type       => short_node_type($dxchan),
            state            => $dxchan->state,
            direction        => $dir,
            cnum             => $cnum,
            connected_since  => utc($dxchan->startt),
            connection_age_s => time - $dxchan->startt,
            connection_age   => age_text(time - $dxchan->startt),
            version          => $route->{version},
            build            => $route->{build},
            registered       => $user->{registered},
            password_defined => $user->{password_defined},
            priv             => $user->{priv},
            isolate          => $user->{isolate},
            pc9x             => jbool($dxchan->{do_pc9x}),
        };

        if ($dxchan->is_rbn || $rbn_exception{$call}) {
            push @rbn_nodes, $item;
        } elsif ($dxchan->is_node) {
            push @neighbours, $item;
        } else {
            push @users, $item;
        }
    }

    return {
        neighbours => \@neighbours,
        rbn_nodes  => \@rbn_nodes,
        users      => \@users,
    };
}

sub count_summary {
    my $connections = shift;

    my ($total_peers, $reg_peers, $pass_peers) = (0, 0, 0);
    my ($total_users, $reg_users, $pass_users) = (0, 0, 0);

    for my $n (@{$connections->{neighbours}}) {
        $total_peers++;
        $reg_peers++  if $n->{registered};
        $pass_peers++ if $n->{password_defined};
    }

    for my $u (@{$connections->{users}}) {
        $total_users++;
        $reg_users++  if $u->{registered};
        $pass_users++ if $u->{password_defined};
    }

    return {
        neighbours_total            => $total_peers,
        neighbours_registered       => $reg_peers,
        neighbours_without_register => $total_peers - $reg_peers,
        neighbours_password         => $pass_peers,
        neighbours_without_password => $total_peers - $pass_peers,

        users_total                 => $total_users,
        users_registered            => $reg_users,
        users_without_register      => $total_users - $reg_users,
        users_password              => $pass_users,
        users_without_password      => $total_users - $pass_users,

        rbn_nodes_total             => scalar @{$connections->{rbn_nodes}},
    };
}




sub trim {
    my $v = shift;
    return undef unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    return $v;
}

sub is_ipv4 {
    my $ip = shift;
    return 0 unless defined $ip;
    return $ip =~ /^(?:\d{1,3}\.){3}\d{1,3}$/ ? 1 : 0;
}

sub is_ipv6 {
    my $ip = shift;
    return 0 unless defined $ip;
    return $ip =~ /:/ ? 1 : 0;
}

sub ipv4_octets {
    my $ip = shift;
    return () unless is_ipv4($ip);
    my @o = split /\./, $ip;
    return () unless @o == 4;
    for my $x (@o) {
        return () unless $x =~ /^\d+$/ && $x >= 0 && $x <= 255;
    }
    return @o;
}

sub is_private_or_local_ipv4 {
    my $ip = shift;
    my @o = ipv4_octets($ip);
    return 1 unless @o == 4;

    return 1 if $o[0] == 0;
    return 1 if $o[0] == 10;
    return 1 if $o[0] == 127;
    return 1 if $o[0] == 169 && $o[1] == 254;
    return 1 if $o[0] == 172 && $o[1] >= 16 && $o[1] <= 31;
    return 1 if $o[0] == 192 && $o[1] == 168;
    return 1 if $o[0] == 100 && $o[1] >= 64 && $o[1] <= 127; # CGNAT
    return 1 if $o[0] >= 224; # multicast/reserved

    return 0;
}

sub is_private_or_local_ipv6 {
    my $ip = shift;
    return 1 unless defined $ip && is_ipv6($ip);

    my $l = lc $ip;

    return 1 if $l eq "::1";
    return 1 if $l =~ /^fe80:/;       # link-local
    return 1 if $l =~ /^fc/i;         # unique local fc00::/7
    return 1 if $l =~ /^fd/i;         # unique local fd00::/8
    return 1 if $l =~ /^::ffff:127\./;
    return 1 if $l =~ /^::ffff:10\./;
    return 1 if $l =~ /^::ffff:192\.168\./;
    return 1 if $l =~ /^::ffff:172\.(1[6-9]|2[0-9]|3[0-1])\./;

    return 0;
}

sub is_public_ip {
    my $ip = trim(shift);
    return 0 unless defined $ip && $ip ne "";

    if (is_ipv4($ip)) {
        return is_private_or_local_ipv4($ip) ? 0 : 1;
    }

    if (is_ipv6($ip)) {
        return is_private_or_local_ipv6($ip) ? 0 : 1;
    }

    return 0;
}


sub is_link_local_ip {
    my $ip = trim(shift);
    return 0 unless defined $ip && $ip ne "";

    if (is_ipv4($ip)) {
        my @o = ipv4_octets($ip);
        return 1 if @o == 4 && $o[0] == 169 && $o[1] == 254;
        return 0;
    }

    if (is_ipv6($ip)) {
        my $l = lc $ip;
        return 1 if $l =~ /^fe[89ab][0-9a-f]*:/; # fe80::/10 link-local
        return 0;
    }

    return 0;
}

sub add_ips_from_text {
    my ($seen, $txt) = @_;
    my $added = 0;

    for my $ip (split /\s+/, $txt || "") {
        $ip = trim($ip);
        next unless defined $ip && $ip ne "";
        next unless is_ipv4($ip) || is_ipv6($ip);

        $seen->{$ip} = 1;
        $added++;
    }

    return $added;
}

sub system_local_ips {
    my %seen;

    # GNU hostname. On BusyBox this may print usage text, so only valid IPs count.
    my $out = `hostname -I 2>/dev/null`;
    my $added = add_ips_from_text(\%seen, $out);

    # BusyBox / Alpine fallback. Use this only if hostname -I gave no valid IPs.
    if (!$added) {
        $out = `hostname -i 2>/dev/null`;
        add_ips_from_text(\%seen, $out);
    }

    # Do not use "ip -o addr show" here.
    # It can add link-local IPv6 addresses such as fe80::/64, which should not
    # be required in @main::localhost_names and causes false Missing Names.
    return sort keys %seen;
}


sub collect_localhost_alias {
    my $alias4;
    my $alias6;
    my @names;

    eval { $alias4 = $main::localhost_alias_ipv4; };
    eval { $alias6 = $main::localhost_alias_ipv6; };
    eval { @names = @main::localhost_names; };

    $alias4 = trim($alias4);
    $alias6 = trim($alias6);

    @names = grep { defined $_ && $_ ne "" } map { trim($_) } @names;

    my @system_ips = system_local_ips();

    my %names = map { $_ => 1 } @names;
    my @missing;
    for my $ip (@system_ips) {
        next if $ip eq "127.0.0.1";
        next if $ip eq "::1";
        next if is_link_local_ip($ip);
        next if $names{$ip};
        push @missing, $ip;
    }

    my $alias4_defined = defined $alias4 && $alias4 ne "";
    my $alias6_defined = defined $alias6 && $alias6 ne "";

    my $alias4_public = $alias4_defined ? is_public_ip($alias4) : 0;
    my $alias6_public = $alias6_defined ? is_public_ip($alias6) : 0;

    my $has_ipv4_local = scalar grep { is_ipv4($_) && is_private_or_local_ipv4($_) } @system_ips;
    my $has_ipv6_local = scalar grep { is_ipv6($_) && is_private_or_local_ipv6($_) } @system_ips;

    return {
        localhost_alias_ipv4 => $alias4,
        localhost_alias_ipv6 => $alias6,
        localhost_alias_ipv4_defined => jbool($alias4_defined),
        localhost_alias_ipv6_defined => jbool($alias6_defined),
        localhost_alias_ipv4_public => jbool($alias4_public),
        localhost_alias_ipv6_public => jbool($alias6_public),
        localhost_names => \@names,
        system_local_ips => \@system_ips,
        missing_localhost_names => \@missing,
        localhost_names_complete => jbool(@missing == 0),
        has_local_ipv4 => jbool($has_ipv4_local),
        has_local_ipv6 => jbool($has_ipv6_local),
        ok => jbool((!$alias4_defined || $alias4_public) &&
                    (!$alias6_defined || $alias6_public) &&
                    @missing == 0),
    };
}


sub collect_anti_abuse {
    # Anti-abuse and validation settings used by DXSpider.
    #
    # senderverify:
    #   0 = disabled
    #   1 = verify/log suspicious PC11/PC61 sender data
    #   2 = verify/drop suspicious PC11/PC61 sender data
    #
    # Spot checks:
    #   do_call_check   = validate spotted callsign
    #   do_by_check     = validate spotter callsign
    #   do_ipaddr_check = validate/check IP-related data where available
    #
    # Important note about do_node_check:
    #   $Spot::do_node_check is not general node authentication. It is an
    #   anti-flood / duplicate-spot node-origin control. DXAudit scores it as
    #   service protection, not as node-password/authentication security.
    #
    # eval is used for compatibility with different DXSpider versions.
    my $senderverify = 0;
    eval { $senderverify = $DXProt::senderverify; };
    $senderverify = 0 unless defined $senderverify;

    # censorpc enables badword filtering on protocol traffic.
    # It is relevant for information hygiene and network protection.
    my $censorpc = 0;
    eval { $censorpc = $DXProt::censorpc; };

    # Informational only. Not used by the server-side score.
    my $do_node_check = 0;
    eval { $do_node_check = $Spot::do_node_check; };

    my $do_call_check = 0;
    eval { $do_call_check = $Spot::do_call_check; };

    my $do_by_check = 0;
    eval { $do_by_check = $Spot::do_by_check; };

    my $do_ipaddr_check = 0;
    eval { $do_ipaddr_check = $Spot::do_ipaddr_check; };

    my $dupecall;
    eval { $dupecall = $Spot::dupecall; };

    my $dupecallthreshold;
    eval { $dupecallthreshold = $Spot::dupecallthreshold; };

    my $nodetime;
    eval { $nodetime = $Spot::nodetime; };

    my $nodetimethreshold;
    eval { $nodetimethreshold = $Spot::nodetimethreshold; };

    return {
        senderverify        => int($senderverify || 0),
        censorpc            => jbool($censorpc),
        do_node_check       => jbool($do_node_check),
        do_call_check       => jbool($do_call_check),
        do_by_check         => jbool($do_by_check),
        do_ipaddr_check     => jbool($do_ipaddr_check),

        # Informational anti-abuse tuning values.
        dupecall            => defined $dupecall ? jbool($dupecall) : undef,
        dupecallthreshold   => $dupecallthreshold,
        nodetime            => $nodetime,
        nodetimethreshold   => $nodetimethreshold,
    };
}


sub collect_protocol {
    my %protocol;

    # senderverify is a DXProt security setting:
    #   0 = disabled
    #   1 = verify and log suspicious PC11/PC61 sender data
    #   2 = verify and reject/drop suspicious PC11/PC61 sender data
    #
    # Use eval blocks because not all DXSpider versions necessarily expose
    # every variable in the same way.
    my $senderverify;
    eval { $senderverify = $DXProt::senderverify; };
    $senderverify = 0 unless defined $senderverify;

    my $pc92_ad_enabled;
    eval { $pc92_ad_enabled = $DXProt::pc92_ad_enabled; };

    my $pc92_ipaddr_enabled;
    eval { $pc92_ipaddr_enabled = $DXProt::pc92c_ipaddr_enable; };

    my $pc92_update_period;
    eval { $pc92_update_period = $DXProt::pc92_update_period; };

    my $pc92_keepalive_period;
    eval { $pc92_keepalive_period = $DXProt::pc92_keepalive_period; };

    my $local_do_pc9x;
    eval {
        $local_do_pc9x = $main::me->{do_pc9x} if defined $main::me;
    };

    return {
        senderverify          => int($senderverify || 0),
        pc9x_enabled          => jbool($local_do_pc9x),
        pc92_ad_enabled       => defined $pc92_ad_enabled ? jbool($pc92_ad_enabled) : undef,
        pc92_ipaddr_enabled   => defined $pc92_ipaddr_enabled ? jbool($pc92_ipaddr_enabled) : undef,
        pc92_update_period    => $pc92_update_period,
        pc92_keepalive_period => $pc92_keepalive_period,
    };
}


sub collect_report {
    my $badlists    = collect_badlists();
    my $connections = collect_connections();
    my $summary     = count_summary($connections);
    my $protocol    = collect_protocol();
    my $anti_abuse  = collect_anti_abuse();
    my $localhost_alias = collect_localhost_alias();

    return {
        schema        => "dxspider-audit-v1.2",
        generated_utc => utc(time),

        node => {
            call              => $main::mycall,
            alias             => $main::myalias,
            version           => $main::version,
            build             => $main::build,
            uptime            => main::uptime(),
            password_required => jbool(defined $main::passwdreq ? $main::passwdreq : 0),
            register_required => jbool(defined $main::reqreg ? $main::reqreg : 0),
        },

        badlists   => $badlists,
        protocol   => $protocol,
        anti_abuse => $anti_abuse,
        localhost_alias => $localhost_alias,
        neighbours => $connections->{neighbours},
        rbn_nodes  => $connections->{rbn_nodes},
        users      => $connections->{users},
        summary    => $summary,
    };
}

sub badlist_status {
    my $age = shift;
    return "MISS"  unless defined $age;
    return "OK"    if $age <= 30;
    return "OLD"   if $age <= 90;
    return "STALE";
}

sub output_json {
    my $report = shift;
    my $json = JSON::PP->new->canonical(1)->pretty(1)->encode($report);
    return split /\n/, $json;
}

sub output_table {
    my $report = shift;
    my @out;

    my $node = $report->{node};
    my $s    = $report->{summary};

    push @out, " ------------------------------------------------------------------------";
    push @out, sprintf "                 Node: %-18s Sysop: %s",
        $node->{call}, $node->{alias};
    push @out, " ------------------------------------------------------------------------";
    push @out, sprintf "          Version: %-23s Register Req: %s",
        $node->{version}, yn($node->{register_required});
    push @out, sprintf "            Build: %4s                    Password Req: %s",
        $node->{build}, yn($node->{password_required});
    push @out, sprintf "           Uptime: %s",
        $node->{uptime};
    push @out, "";

    push @out, " ---------------------------- Security Summary --------------------------";
    push @out, sprintf "          Neighbours: %3d                                Users: %3d",
        $s->{neighbours_total}, $s->{users_total};
    push @out, sprintf "       With Register: %3d                        With Register: %3d",
        $s->{neighbours_registered}, $s->{users_registered};
    push @out, sprintf "    Without Register: %3d                     Without Register: %3d",
        $s->{neighbours_without_register}, $s->{users_without_register};
    push @out, sprintf "       With Password: %3d                        With Password: %3d",
        $s->{neighbours_password}, $s->{users_password};
    push @out, sprintf "    Without Password: %3d                     Without Password: %3d",
        $s->{neighbours_without_password}, $s->{users_without_password};
    push @out, sprintf "           RBN nodes: %3d",
        $s->{rbn_nodes_total};
    push @out, "";

    push @out, sprintf "       Sender Verify: %3s                             PC92 A/D: %3s",
        defined $report->{anti_abuse}{senderverify}
            ? $report->{anti_abuse}{senderverify}
            : (defined $report->{protocol}{senderverify}
                ? $report->{protocol}{senderverify}
                : "-"),
        yn($report->{protocol}{pc92_ad_enabled});

    push @out, sprintf "          Node Check: %3s                             PC92C IP: %3s",
        yn($report->{anti_abuse}{do_node_check}),
        yn($report->{protocol}{pc92_ipaddr_enabled});

    push @out, sprintf "        DXCall Check: %3s                           Alias IPv4: %3s",
        yn($report->{anti_abuse}{do_call_check}),
        yn($report->{localhost_alias}{localhost_alias_ipv4_public});

    push @out, sprintf "       Spotter Check: %3s                           Alias IPv6: %3s",
        yn($report->{anti_abuse}{do_by_check}),
        yn($report->{localhost_alias}{localhost_alias_ipv6_public});

    push @out, sprintf "           Censor PC: %3s                      Localhost Names: %3s",
        yn($report->{anti_abuse}{censorpc}),
        yn($report->{localhost_alias}{localhost_names_complete});

    push @out, sprintf "            IP Check: %3s                        Missing Names: %3d",
        yn($report->{anti_abuse}{do_ipaddr_check}),
        scalar @{$report->{localhost_alias}{missing_localhost_names} || []};

    push @out, "";

    push @out, " ------------------------------- Badlists -------------------------------";
    push @out, " List        Newest file              Age(d) Entries  Status";
    push @out, " ----------  -----------------------  ------ -------  ------";

    for my $name (qw(baddx badip badnode badspotter badword)) {
        next unless exists $report->{badlists}{$name};
        my $b = $report->{badlists}{$name}{newest};

        push @out, sprintf " %-10s  %-23s  %6s %7s  %-6s",
            $name,
            defined $b->{name} ? $b->{name} : "-",
            defined $b->{age_days} ? $b->{age_days} : "-",
            defined $b->{entries} ? $b->{entries} : 0,
            badlist_status($b->{age_days});
    }

    push @out, "";

    push @out, " ------------------------------ Neighbours ------------------------------";
    push @out, " Call         Type  Version  Build  R P  Iso  Dir  State    Conn Time";
    push @out, " -----------  ----  -------  -----  - -  ---  ---  -------  ------------";

    for my $n (@{$report->{neighbours}}) {
        push @out, sprintf " %-11s  %-4s  %7s  %5s  %1s %1s  %3s  %-3s %-7s  %12s",
            $n->{call},
            $n->{short_type},
            defined $n->{version} ? $n->{version} : "-",
            defined $n->{build}   ? $n->{build}   : "-",
            yn($n->{registered}),
            yn($n->{password_defined}),
            yn($n->{isolate}),
            $n->{direction} || "-",
            $n->{state} || "-",
            $n->{connection_age};
    }

    push @out, "";

    push @out, " ------------------------------- RBN Nodes ------------------------------";
    push @out, " Call         Type  R P  Dir  State    Conn Time";
    push @out, " -----------  ----  - -  ---  -------  ------------";

    for my $r (@{$report->{rbn_nodes}}) {
        push @out, sprintf " %-11s  %-4s  %1s %1s  %-3s  %-7s  %12s",
            $r->{call},
            $r->{short_type},
            yn($r->{registered}),
            yn($r->{password_defined}),
            $r->{direction} || "-",
            $r->{state} || "-",
            $r->{connection_age};
    }

    push @out, "";
    push @out, " ------------------------------------------------------------------------";

    return @out;
}

sub have_openssl {
    system("which openssl >/dev/null 2>&1");
    return $? == 0;
}

sub have_curl {
    system("which curl >/dev/null 2>&1");
    return $? == 0;
}

sub key_exists {
    return -r $KEY_FILE && -r $PUB_FILE;
}

sub openssl_supports_ed25519 {
    return 0 unless have_openssl();

    my $tmp_key = "$AUDIT_DIR/audit.test.ed25519.key.$$";
    my $tmp_msg = "$AUDIT_DIR/audit.test.ed25519.msg.$$";
    my $tmp_sig = "$AUDIT_DIR/audit.test.ed25519.sig.$$";

    unlink $tmp_key if -e $tmp_key;
    unlink $tmp_msg if -e $tmp_msg;
    unlink $tmp_sig if -e $tmp_sig;

    my $ok = 0;

    my $cmd1 = "openssl genpkey -algorithm ED25519 -out '$tmp_key' >/dev/null 2>&1";
    system($cmd1);

    if ($? == 0 && write_file($tmp_msg, "dxspider-audit-ed25519-test", 0600)) {
        my $cmd2 = "openssl pkeyutl -sign -rawin -inkey '$tmp_key' -in '$tmp_msg' -out '$tmp_sig' >/dev/null 2>&1";
        system($cmd2);
        $ok = 1 if $? == 0 && -s $tmp_sig;
    }

    unlink $tmp_key if -e $tmp_key;
    unlink $tmp_msg if -e $tmp_msg;
    unlink $tmp_sig if -e $tmp_sig;

    return $ok;
}

sub generate_keypair {
    return 0 unless have_openssl();

    unlink $KEY_FILE if -e $KEY_FILE;
    unlink $PUB_FILE if -e $PUB_FILE;

    my ($cmd1, $key_alg);

    # Preferred behaviour:
    #   - Use Ed25519 when the local OpenSSL command line can generate and sign it.
    #   - Fall back to RSA only for compatibility with older systems.
    #
    # This avoids forcing RSA on modern OpenSSL 3.x installations.
    if (openssl_supports_ed25519()) {
        $key_alg = "Ed25519";
        $cmd1 = "openssl genpkey -algorithm ED25519 -out '$KEY_FILE' >/dev/null 2>&1";
    } else {
        $key_alg = "RSA";
        $cmd1 = "openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out '$KEY_FILE' >/dev/null 2>&1";
    }

    my $cmd2 = "openssl pkey -in '$KEY_FILE' -pubout -out '$PUB_FILE' >/dev/null 2>&1";

    system($cmd1);
    return 0 unless $? == 0;

    system($cmd2);
    return 0 unless $? == 0;

    chmod 0600, $KEY_FILE;
    chmod 0644, $PUB_FILE;

    audit_log("generated local $key_alg keypair");

    return 1;
}

sub private_key_type {
    return undef unless have_openssl();
    return undef unless -r $KEY_FILE;

    my $out = `openssl pkey -in '$KEY_FILE' -text -noout 2>/dev/null`;
    $out = trim($out);

    return "Ed25519" if defined $out && $out =~ /ED25519/i;

    # OpenSSL often prints RSA keys starting with:
    #   Private-Key: (2048 bit, 2 primes)
    # and not with the literal string "RSA" on the first line.
    return "RSA" if defined $out && (
        $out =~ /RSA/i ||
        $out =~ /Private-Key:\s*\(\d+\s+bit/i ||
        $out =~ /modulus:/i ||
        $out =~ /privateExponent:/i
    );

    return undef;
}

sub sign_payload {
    my $payload = shift;
    return undef unless have_openssl();
    return undef unless -r $KEY_FILE;

    my $tmp_payload = "$AUDIT_DIR/audit.payload.$$";
    my $tmp_sig     = "$AUDIT_DIR/audit.sig.$$";

    write_file($tmp_payload, $payload, 0600) or return undef;

    my $key_type = private_key_type() || "UNKNOWN";
    my $alg;
    my $cmd;

    if ($key_type eq "RSA") {
        $alg = "RSA-SHA256";
        $cmd = "openssl dgst -sha256 -sign '$KEY_FILE' -out '$tmp_sig' '$tmp_payload' >/dev/null 2>&1";
    } elsif ($key_type eq "Ed25519") {
        $alg = "Ed25519";
        $cmd = "openssl pkeyutl -sign -rawin -inkey '$KEY_FILE' -in '$tmp_payload' -out '$tmp_sig' >/dev/null 2>&1";
    } else {
        audit_log("unknown private key type");
        unlink $tmp_payload;
        return undef;
    }

    system($cmd);

    unlink $tmp_payload;

    if ($? != 0 || !-r $tmp_sig) {
        audit_log("sign failed key_type=$key_type alg=$alg");
        unlink $tmp_sig if -e $tmp_sig;
        return undef;
    }

    my $sig = read_file($tmp_sig);
    unlink $tmp_sig;

    return {
        alg => $alg,
        hex => unpack("H*", $sig),
    };
}

sub post_json {
    my ($endpoint, $obj) = @_;

    return {
        ok => jbool(0),
        status => "NO_CURL",
        message => "curl is not available"
    } unless have_curl();

    my $json = JSON::PP->new->canonical(1)->encode($obj);
    my $req  = "$AUDIT_DIR/audit.req.$$";
    my $res  = "$AUDIT_DIR/audit.res.$$";

    write_file($req, $json, 0600) or return {
        ok => jbool(0),
        status => "LOCAL_ERROR",
        message => "cannot write temporary request"
    };

    my $url = "$AUDIT_SERVER$endpoint";
    my $cmd = "curl -fsS -m 20 -H 'Content-Type: application/json' --data-binary '\@$req' '$url' > '$res' 2>> '$DEBUG_FILE'";
    system($cmd);

    unlink $req;

    if ($? != 0) {
        unlink $res if -e $res;
        return {
            ok => jbool(0),
            status => "HTTP_ERROR",
            message => "server request failed"
        };
    }

    my $txt = read_file($res);
    unlink $res;

    my $decoded;
    eval { $decoded = JSON::PP->new->relaxed(1)->decode($txt); };

    if ($@ || !$decoded) {
        return {
            ok => jbool(0),
            status => "BAD_RESPONSE",
            message => "server response is not valid JSON"
        };
    }

    return $decoded;
}

sub public_key_text {
    my $pub = read_file($PUB_FILE);
    $pub =~ s/\s+$// if defined $pub;
    return $pub;
}

sub enrol_or_rekey {
    my ($force_rekey) = @_;

    my $node = $main::mycall;

    if (key_exists() && !$force_rekey) {
        return {
            ok => jbool(1),
            status => "ALREADY_HAS_CREDENTIALS",
            message => "local audit credentials already exist"
        };
    }

    if (!key_exists() || $force_rekey) {
        generate_keypair() or return {
            ok => jbool(0),
            status => "KEYGEN_FAILED",
            message => "cannot generate local signing key"
        };
    }

    my $pub = public_key_text();

    my $request = {
        node => $node,
        public_key => $pub,
        created_utc => utc(time),
        action => $force_rekey ? "rekey" : "enroll_or_rekey",
        agent => {
            schema => "dxspider-audit-v1.2",
            command => "audit.pl",
        },
    };

    audit_log("sending enrol/rekey request for $node");

    my $response = post_json("/api/v1/audit/enroll", $request);

    if (!$response->{ok}) {
        audit_log("enrol/rekey failed: " . ($response->{status} || "unknown"));
        return $response;
    }

    if ($response->{status} && $response->{status} eq "ENROLLED") {
        write_json_file($CONF_FILE, {
            node => $node,
            server => $AUDIT_SERVER,
            enrolled_utc => utc(time),
            public_key_sha256 => sha256_hex($pub),
        }, 0600);

        write_json_file($STATUS_FILE, {
            node => $node,
            status => "ENROLLED",
            updated_utc => utc(time),
        }, 0600);

        audit_log("enrolment completed");
        return $response;
    }

    if ($response->{status} && $response->{status} eq "REKEY_PENDING") {
        write_json_file($STATUS_FILE, {
            node => $node,
            status => "PENDING_VALIDATION",
            request_id => $response->{request_id},
            updated_utc => utc(time),
        }, 0600);

        audit_log("rekey pending validation request_id=" . ($response->{request_id} || ""));
        return $response;
    }

    audit_log("enrol/rekey response status=" . ($response->{status} || "unknown"));
    return $response;
}

sub signed_report_envelope {
    my $report = shift;

    my $payload = JSON::PP->new->canonical(1)->encode($report);
    my $sig = sign_payload($payload);

    return undef unless defined $sig && ref($sig) eq "HASH";

    return {
        node => $main::mycall,
        created_utc => utc(time),
        payload_sha256 => sha256_hex($payload),
        signature_alg => $sig->{alg},
        signature_hex => $sig->{hex},
        public_key_sha256 => sha256_hex(public_key_text() || ""),
        report => $report,
    };
}

sub send_report {
    my $report = shift;

    if (!key_exists()) {
        audit_log("no local credentials found, starting enrolment");

        my $enrol = enrol_or_rekey(0);

        if (!$enrol->{ok}) {
            return {
                ok => jbool(0),
                status => $enrol->{status},
                message => $enrol->{message},
                request_id => $enrol->{request_id},
            };
        }

        if ($enrol->{status} && $enrol->{status} eq "REKEY_PENDING") {
            return {
                ok => jbool(0),
                status => "PENDING_VALIDATION",
                message => "rekey request is pending validation",
                request_id => $enrol->{request_id},
            };
        }
    }

    my $env = signed_report_envelope($report);

    unless ($env) {
        my $key_type = private_key_type() || "UNKNOWN";

        # Compatibility migration:
        # OpenSSL 1.1.1 cannot sign Ed25519 using the CLI method used here.
        # If an old Ed25519 local key exists and signing fails, generate a new
        # RSA keypair, then continue. The report path below will enrol/rekey
        # the current local public key if the server does not recognise it.
        if ($key_type eq "Ed25519") {
            audit_log("Ed25519 signing failed; generating RSA compatibility keypair");

            if (generate_keypair()) {
                $env = signed_report_envelope($report);
            }
        }
    }

    unless ($env) {
        audit_log("cannot sign report");
        return {
            ok => jbool(0),
            status => "SIGN_FAILED",
            message => "cannot sign report; check local OpenSSL key support and audit.debug"
        };
    }

    audit_log("sending signed report");

    my $response = post_json("/api/v1/audit/report", $env);

    if ($response->{status} && $response->{status} eq "REKEY_REQUIRED") {
        audit_log("server reported missing/mismatched key, trying to register current local key");

        my $pub = public_key_text();

        my $request = {
            node => $main::mycall,
            public_key => $pub,
            created_utc => utc(time),
            action => "enroll_existing_local_key",
            agent => {
                schema => "dxspider-audit-v1.2",
                command => "audit.pl",
            },
        };

        my $enrol = post_json("/api/v1/audit/enroll", $request);

        if ($enrol->{ok} && $enrol->{status} && $enrol->{status} eq "ENROLLED") {
            audit_log("current local key enrolled, retrying report");

            write_json_file($CONF_FILE, {
                node => $main::mycall,
                server => $AUDIT_SERVER,
                enrolled_utc => utc(time),
                public_key_sha256 => sha256_hex($pub),
            }, 0600);

            $response = post_json("/api/v1/audit/report", $env);
        }
        elsif ($enrol->{ok} && $enrol->{status} && $enrol->{status} eq "REKEY_PENDING") {
            write_json_file($STATUS_FILE, {
                node => $main::mycall,
                status => "PENDING_VALIDATION",
                request_id => $enrol->{request_id},
                updated_utc => utc(time),
            }, 0600);

            return {
                ok => jbool(0),
                status => "PENDING_VALIDATION",
                message => "rekey request is pending validation",
                request_id => $enrol->{request_id},
            };
        }
        else {
            return {
                ok => jbool(0),
                status => $enrol->{status} || "ENROL_FAILED",
                message => $enrol->{message} || "cannot enrol current local key",
                request_id => $enrol->{request_id},
            };
        }
    }

    if ($response->{ok}) {
        write_json_file($STATUS_FILE, {
            node => $main::mycall,
            status => "SENT",
            report_id => $response->{report_id},
            updated_utc => utc(time),
        }, 0600);

        audit_log("report sent report_id=" . ($response->{report_id} || ""));
    } else {
        audit_log("send failed status=" . ($response->{status} || "unknown"));
    }

    return $response;
}

sub output_send_result {
    my $res = shift;
    my @out;

    push @out, " ------------------------------ Audit Send -------------------------------";
    push @out, sprintf " Node: %s", $main::mycall;
    push @out, "";

    my $status = $res->{status} || ($res->{ok} ? "SENT" : "UNKNOWN");

    if ($res->{ok}) {
        push @out, " Report signed.";
        push @out, " Report uploaded successfully.";
        push @out, "";
        push @out, sprintf " Server: %s", $AUDIT_SERVER;
        push @out, sprintf " Report ID: %s", $res->{report_id} || "-";
    } elsif ($status eq "PENDING_VALIDATION" || $status eq "REKEY_PENDING") {
        push @out, " Existing registration found.";
        push @out, "";
        push @out, " The local credentials do not match the credentials";
        push @out, " currently registered for this node.";
        push @out, "";
        push @out, " Rekey request submitted.";
        push @out, "";
        push @out, " Status: PENDING VALIDATION";
        push @out, sprintf " Request ID: %s", $res->{request_id} || "-";
    } else {
        push @out, sprintf " Status: %s", $status;
        push @out, "";
        push @out, sprintf " Message: %s", $res->{message} || "-";
    }

    push @out, " ------------------------------------------------------------------------";

    return @out;
}

sub output_rekey_result {
    my $res = shift;
    my @out;

    push @out, " ------------------------------- Audit Rekey -----------------------------";
    push @out, sprintf " Node: %s", $main::mycall;
    push @out, "";

    if ($res->{status} && $res->{status} eq "REKEY_PENDING") {
        push @out, " Rekey request submitted.";
        push @out, "";
        push @out, " Status: PENDING VALIDATION";
        push @out, sprintf " Request ID: %s", $res->{request_id} || "-";
    } elsif ($res->{ok}) {
        push @out, sprintf " Status: %s", $res->{status} || "OK";
    } else {
        push @out, sprintf " Status: %s", $res->{status} || "FAILED";
        push @out, sprintf " Message: %s", $res->{message} || "-";
    }

    push @out, " ------------------------------------------------------------------------";

    return @out;
}

my $report = collect_report();

if ($mode eq "json") {
    return (1, output_json($report));
}

if ($mode eq "send") {
    my $res = send_report($report);
    return (1, output_send_result($res));
}

if ($mode eq "rekey") {
    my $res = enrol_or_rekey(1);
    return (1, output_rekey_result($res));
}

return (1, output_table($report));
