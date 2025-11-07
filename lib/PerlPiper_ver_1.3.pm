package PerlPiper;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(run_task);
use Net::OpenSSH;

sub run_task {
    my %p = @_;
    my $ssh       = $p{ssh};
    my $ip        = $p{ip};
    my $mod       = $p{module};
    my $args      = $p{args} // {};
    my $become    = $p{become};
    my $sudo      = $become ? 'sudo ' : '';
    my $play_vars = $p{play_vars} // {};

    my %vars = (
        inventory_hostname => $ip,
        admin              => $play_vars->{admin} // 'Flautista',
        %$play_vars,
    );

    if ($mod eq 'template') {
        my $src  = $args->{src};
        my $dest = $args->{dest};
        my $template_vars = $args->{vars} // {};

        # Mescla todas as variáveis
        my %all_vars = (%vars, %$template_vars);

        open my $fh, '<', $src or return { changed => 0, error => "Cannot open $src" };
        my $content = do { local $/; <$fh> };
        close $fh;

        # Substitui {{ var }} 
        $content =~ s/\{\{\s*([a-zA-Z_]\w*)\s*\}\}/
            do { exists $all_vars{$1} ? $all_vars{$1} : '' }
        /ge;

        # Substitui {{ lookup('pipe', 'cmd') }}
        $content =~ s!
            \{\{\s*lookup\s*\(\s*['"]pipe['"],\s*['"]([^'"]+)['"]\s*\)\s*\}\}
        !
            do {
                my $out = $ssh->capture($1) // '';
                chomp $out;
                $out
            }
        !gex;

        my $remote = $ssh->capture("cat '$dest' 2>/dev/null || echo ''") // '';
        chomp $remote;
        return { changed => 0 } if $remote eq $content;

        my $tmp = "/tmp/motd-$$";
        open my $fh2, '>', $tmp or die $!;
        print $fh2 $content;
        close $fh2;
        $ssh->scp_put($tmp, $dest);
        $ssh->system("$sudo chown root:root '$dest'");
        unlink $tmp;
        return { changed => 1 };
    }

    if ($mod eq 'package') {
        my $pkg = $args->{name};
        my $state = $args->{state} // 'present';
        
        if ($state eq 'present') {
            my $out = $ssh->capture("dpkg -s $pkg 2>/dev/null | grep ^Status") // '';
            return { changed => 0 } if $out =~ /install ok/;
            $ssh->system("$sudo apt-get update -qq && $sudo apt-get install -y $pkg");
            return { changed => 1 };
        }
        return { changed => 0 };
    }

    if ($mod eq 'service') {
        my $svc = $args->{name};
        my $state = $args->{state} // 'started';
        
        if ($state eq 'started') {
            my $status = $ssh->capture("systemctl is-active $svc 2>/dev/null || echo inactive") // '';
            chomp $status;
            return { changed => 0 } if $status eq 'active';
            
            $ssh->system("$sudo systemctl daemon-reload");
            my $exit = $ssh->system("$sudo systemctl restart $svc");
            if ($exit != 0) {
                $ssh->system("$sudo systemctl start $svc");
            }
            return { changed => 1 };
        }
        return { changed => 0 };
    }

    if ($mod eq 'shell') {
        my $cmd;
        
        if (ref($args) eq 'HASH') {
            $cmd = $args->{cmd};
            unless (defined $cmd && $cmd ne '') {
                $cmd = $args->{shell} // $args->{command} // '';
            }
        } else {
            $cmd = $args;
        }
        
        $cmd =~ s/^\s+|\s+$//g if defined $cmd;
        
        unless (defined $cmd && $cmd ne '') {
            return { changed => 0 };
        }
        
        $ssh->system("$sudo$cmd");
        return { changed => 1 };
    }

    if ($mod eq 'copy') {
        my $content = $args->{content} // '';
        my $dest    = $args->{dest};
        my $remote  = $ssh->capture("cat '$dest' 2>/dev/null || echo ''") // '';
        chomp $remote;
        return { changed => 0 } if $remote eq $content;
        my $tmp = "/tmp/copy-$$";
        open my $fh, '>', $tmp or die $!;
        print $fh $content;
        close $fh;
        $ssh->scp_put($tmp, $dest);
        $ssh->system("$sudo chown root:root '$dest'");
        unlink $tmp;
        return { changed => 1 };
    }

    return { changed => 0, error => "Módulo $mod não implementado" };
}
1;
