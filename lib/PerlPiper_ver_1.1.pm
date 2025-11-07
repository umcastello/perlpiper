package PerlPiper;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(run_task);

use Net::OpenSSH;

sub run_task {
    my %p = @_;
    my $ssh    = $p{ssh};
    my $mod    = $p{module};
    my $args   = $p{args};
    my $become = $p{become};

    my $sudo = $become ? 'sudo ' : '';

    if ($mod eq 'package') {
        my $pkg = $args->{name};
        my ($installed) = $ssh->capture("dpkg -s $pkg 2>/dev/null | grep ^Status");
        return { changed => 0 } if $installed && $installed =~ /install ok/;
        $ssh->system("$sudo apt-get update -qq && $sudo apt-get install -y $pkg");
        return { changed => 1 };
    }

    if ($mod eq 'service') {
        my $svc = $args->{name};
        my ($status) = $ssh->capture("systemctl is-active $svc 2>/dev/null || echo inactive");
        chomp $status;
        if ($status ne 'active') {
            $ssh->system("$sudo systemctl start $svc");
            return { changed => 1 };
        }
        return { changed => 0 };
    }

    if ($mod eq 'copy') {
        my $content = $args->{content} // '';
        my $dest    = $args->{dest};
        my ($remote) = $ssh->capture("cat '$dest' 2>/dev/null || echo ''");
        chomp $remote;
        return { changed => 0 } if $remote eq $content;

        my $tmp = "/tmp/perlpiper-$$";
        open my $fh, '>', $tmp or die $!;
        print $fh $content;
        close $fh;
        $ssh->scp_put($tmp, $dest);
        $ssh->system("$sudo chown root:root '$dest'");
        unlink $tmp;
        return { changed => 1 };
    }

    if ($mod eq 'file') {
        my $path = $args->{path};
        my $state = $args->{state} // 'directory';
        if ($state eq 'directory') {
            my ($exists) = $ssh->capture("test -d '$path' && echo yes");
            unless ($exists) {
                $ssh->system("$sudo mkdir -p '$path'");
                $ssh->system("$sudo chown $args->{owner}:$args->{group} '$path'") if $args->{owner};
                return { changed => 1 };
            }
        }
        return { changed => 0 };
    }

    return { changed => 0, error => "módulo desconhecido: $mod" };
}

1;
