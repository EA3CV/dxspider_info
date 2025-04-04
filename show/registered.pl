#
# show/registered
#
# show all registered users
#
# Copyright (c) 2001 Dirk Koopman G1TLH
#
# Modify by Kin EA3CV, ea3cv@cronux.net
#
# 20250403 v0.1
#

sub handle
{
        my ($self, $line) = @_;
        return (1, $self->msg('e5')) unless $self->priv >= 9;

        my @out;

        use DB_File;

        if ($line) {
                $line =~ s/[^\w\-\/]+//g;
                $line = "\U\Q$line";
        }

        if ($self->{_nospawn} || $main::is_win == 1) {
                @out = generate($self, $line);
        } else {
                @out = $self->spawn_cmd("show/registered $line", sub { return (generate($self, $line)); });
        }

        return (1, @out);
}

sub generate
{
        my $self = shift;
        my $line = shift;
        my @out;
        my @val;

        my %call = ();
        $call{$_} = 1 for split /\s+/, $line;
        delete $call{'ALL'};

        my ($action, $count, $key, $data) = (0,0,0,0);
        unless (keys %call) {
                for ($action = DXUser::R_FIRST, $count = 0; !$DXUser::dbm->seq($key, $data, $action); $action = DXUser::R_NEXT) {
                        # cambio mínimo aquí ↓
                        if ($data =~ /"registered":"1"/) {
                                $call{$key} = 1;
                        }
                }
        }

        foreach $key (sort keys %call) {
                my $u = DXUser::get_current($key);
                if ($u && defined (my $r = $u->registered)) {
                        push @val, "${key}($r)";
                        ++$count;
                }
        }

        my @l;
        push @out, "Registration is " . ($main::reqreg ? "Required" :  "NOT Required");
        foreach my $call (@val) {
                if (@l >= 5) {
                        push @out, sprintf "%-14s %-14s %-14s %-14s %-14s", @l;
                        @l = ();
                }
                push @l, $call;
        }
        if (@l) {
                push @l, "" while @l < 5;
                push @out, sprintf "%-14s %-14s %-14s %-14s %-14s", @l;
        }

        push @out, $self->msg('rec', $count);
        return @out;
}

