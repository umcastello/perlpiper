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

        open my $fh, '<', $src or return { changed => 0 };
        my $content = do { local $/; <$fh> };
        close $fh;

        # {{ var }} — 100% FUNCIONA
        $content =~ s/\{\{\s*([a-zA-Z_]\w*)\s*\}\}/
            do { exists $vars{$1} ? $vars{$1} : '' }
        /ge;

        # {{ lookup('pipe', 'cmd') }} — 100% FUNCIONA
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
        my $out = $ssh->capture("dpkg -s $pkg 2>/dev/null | grep ^Status") // '';
        return { changed => 0 } if $out =~ /install ok/;
        $ssh->system("$sudo apt-get update -qq && $sudo apt-get install -y $pkg");
        return { changed => 1 };
    }

    if ($mod eq 'service') {
        my $svc = $args->{name};
        my $status = $ssh->capture("systemctl is-active $svc 2>/dev/null || echo inactive") // '';
        chomp $status;
        return { changed => 0 } if $status eq 'active';
        $ssh->system("$sudo systemctl daemon-reload");
        $ssh->system("$sudo systemctl restart $svc || $sudo systemctl start $svc");
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

    return { changed => 0 };
}
1;
