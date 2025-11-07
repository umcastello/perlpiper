#!/usr/bin/env perl
use FindBin qw($Bin);
use lib "$Bin/lib";
use strict;
use warnings;
use PerlPiper;
use YAML::XS qw(LoadFile);
use Term::ANSIColor qw(colored);

# ♫ O FLAUTISTA TOCA ♫
BEGIN {
    system('printf "\e[38;5;226m"');
    print <<'BANNER';

   _____           _       _____ _             
  |  __ \         | |     |  __ (_)            
  | |__) |__ _ __ | |     | |__) | _ __   ___  
  |  ___/ _ \ '__| |     |  ___/ | '_ \ / _ \ 
  | |  |  __/ |  | |____ | |   | | |_) |  __/ 
  |_|   \___|_|  |______|_|   |_| .__/ \___| 
                                        | |    
                                        |_|    
                ♫ TOCANDO PARA 1000 RATOS ♫
BANNER
    system('printf "\e[0m\n\a"');
}

die colored("Playbook não encontrado!\n", 'red') unless -f 'playbook.yml';
my $playbook  = LoadFile('playbook.yml');
my $inventory = parse_inventory('hosts.ini');

for my $play (@$playbook) {
    my $group  = $play->{hosts};
    my $tasks  = $play->{tasks} // [];
    my $become = $play->{become} // 0;
    my $vars   = $play->{vars} // {};

    print colored("\n=== PLAY: $play->{name} ===\n", 'bold yellow');

    for my $h (@{ $inventory->{$group} || [] }) {
        my $ip   = $h->{ip};
        my $user = $h->{user};
        my $key  = $h->{key};

        print colored("Host: $ip (user=$user)\n", 'cyan');

        my $ssh = Net::OpenSSH->new(
            $ip,
            user     => $user,
            key_path => $key || undef,
            timeout  => 10,
        );
        die "SSH falhou em $ip: ".$ssh->error if $ssh->error;

        for my $task (@$tasks) {
            my ($mod) = keys %$task;
            my $name  = $task->{name} // $mod;
            print " [$name] ... ";
            my $r = PerlPiper::run_task(
                ssh       => $ssh,
                ip        => $ip,  # ← CORREÇÃO AQUI
                module    => $mod,
                args      => $task->{$mod},
                become    => $become,
                play_vars => $vars,  # ← CORREÇÃO AQUI
            );
            print $r->{changed}
                ? colored("CHANGED\n", 'green')
                : colored("OK\n", 'blue');
        }
    }
}

sub parse_inventory {
    my %inv;
    open my $fh, '<', 'hosts.ini' or die "hosts.ini: $!\n";
    my $group = '';
    while (<$fh>) {
        chomp;
        next if /^\s*#|^\s*$/;
        if (/^\[(.+)\]/) { $group = $1; next; }
        next unless $group;

        my ($ip, @vars) = split /\s+/;
        my %v;
        for (@vars) {
            my ($k, $val) = split /=/, $_, 2;
            $val =~ s/^["']|["']$//g;
            $v{$k} = $val if $k =~ /^ansible_/;
        }
        push @{$inv{$group}}, {
            ip   => $ip,
            user => $v{ansible_user} // 'root',
            key  => $v{ansible_ssh_private_key_file} // '',
        };
    }
    close $fh;
    return \%inv;
}

print colored("\n♪ TODOS OS SERVIDORES DANÇAM AO SOM DA FLAUTA ♪\n", 'bold magenta');
