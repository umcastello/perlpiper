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

    if ($mod eq 'user') {
        my $name = $args->{name};
        my $state = $args->{state} // 'present';
        
        if ($state eq 'present') {
            # Verifica se usuário já existe
            my $exists = $ssh->capture("id '$name' 2>/dev/null && echo 'EXISTS'");
            if ($exists =~ /EXISTS/) {
                # Usuário existe, verifica se precisa modificar
                my $changed = 0;
                
                # Verifica shell
                if ($args->{shell}) {
                    my $current_shell = $ssh->capture("getent passwd '$name' | cut -d: -f7");
                    chomp $current_shell;
                    if ($current_shell ne $args->{shell}) {
                        $ssh->system("$sudo usermod -s '$args->{shell}' '$name'");
                        $changed = 1;
                    }
                }
                
                # Verifica grupos
                if ($args->{groups}) {
                    my $current_groups = $ssh->capture("groups '$name'");
                    my @groups = split /\s+/, $args->{groups};
                    foreach my $group (@groups) {
                        unless ($current_groups =~ /\b$group\b/) {
                            $ssh->system("$sudo usermod -aG '$group' '$name'");
                            $changed = 1;
                        }
                    }
                }
                
                return { changed => $changed };
            } else {
                # Cria novo usuário
                my $cmd = "useradd";
                $cmd .= " -s " . $args->{shell} if $args->{shell};
                $cmd .= " -m" if $args->{create_home};  # Cria home directory
                $ssh->system("$sudo$cmd '$name'");
                
                # Configura grupos se especificado
                if ($args->{groups}) {
                    $ssh->system("$sudo usermod -aG '$args->{groups}' '$name'");
                }
                
                return { changed => 1 };
            }
        }
        
        if ($state eq 'absent') {
            # Remove usuário
            my $exists = $ssh->capture("id '$name' 2>/dev/null && echo 'EXISTS'");
            return { changed => 0 } unless $exists =~ /EXISTS/;
            
            my $cmd = "userdel";
            $cmd .= " -r" if $args->{remove_home};  # Remove home directory
            $ssh->system("$sudo$cmd '$name'");
            return { changed => 1 };
        }
        
        return { changed => 0, error => "Estado '$state' não suportado para usuário" };
    }

    if ($mod eq 'file') {
        my $path = $args->{path};
        my $state = $args->{state} // 'file';
        
        if ($state eq 'directory') {
            # Verifica se diretório já existe - MÉTODO CORRIGIDO
            my $check_cmd = "if [ -d '$path' ]; then echo 'EXISTS'; else echo 'NOT_EXISTS'; fi";
            my $exists = $ssh->capture($check_cmd);
            chomp $exists;
            $exists =~ s/^\s+|\s+$//g;  # Remove espaços
           
            warn "DEBUG file/directory: path='$path', detected='$exists'\n";
            
            if ($exists eq 'EXISTS') {
                warn "DEBUG: Diretório JÁ EXISTE, verificando permissões\n";
                # Diretório existe, verifica se precisa modificar permissões
                my $changed = 0;
                
                # Verifica owner - método compatível
                if ($args->{owner}) {
                    my $current_owner = $ssh->capture("ls -ld '$path' | awk '{print \$3}'");
                    chomp $current_owner;
                    if ($current_owner ne $args->{owner}) {
                        $ssh->system("$sudo chown '$args->{owner}' '$path'");
                        $changed = 1;
                    }
                }
                
                # Verifica group - método compatível
                if ($args->{group}) {
                    my $current_group = $ssh->capture("ls -ld '$path' | awk '{print \$4}'");
                    chomp $current_group;
                    if ($current_group ne $args->{group}) {
                        $ssh->system("$sudo chgrp '$args->{group}' '$path'");
                        $changed = 1;
                    }
                }
                
                # Verifica mode (permissões) - método compatível
                if ($args->{mode}) {
                    my $current_mode_str = $ssh->capture("ls -ld '$path' | awk '{print \$1}'");
                    chomp $current_mode_str;



                    # Converte rwx para numérico - MÉTODO CORRIGIDO
                    my $current_mode = '';
                    if ($current_mode_str =~ /^d(...)(...)(...)/) {
                        my ($u, $g, $o) = ($1, $2, $3);
                        # Converte cada parte individualmente
                        my $u_num = ($u =~ /r/ ? 4 : 0) + ($u =~ /w/ ? 2 : 0) + ($u =~ /x/ ? 1 : 0);
                        my $g_num = ($g =~ /r/ ? 4 : 0) + ($g =~ /w/ ? 2 : 0) + ($g =~ /x/ ? 1 : 0);
                        my $o_num = ($o =~ /r/ ? 4 : 0) + ($o =~ /w/ ? 2 : 0) + ($o =~ /x/ ? 1 : 0);
                        $current_mode = sprintf("%d%d%d", $u_num, $g_num, $o_num);
                    }




                    if ($current_mode ne $args->{mode}) {
                        $ssh->system("$sudo chmod '$args->{mode}' '$path'");
                        $changed = 1;
                    }
                }
                
                return { changed => $changed };
            } else {
                warn "DEBUG: Diretório NÃO EXISTE, criando...\n";
                # Cria novo diretório
                $ssh->system("$sudo mkdir -p '$path'");
                
                # Configura permissões se especificado
                if ($args->{owner} || $args->{group}) {
                    my $owner_group = '';
                    if ($args->{owner} && $args->{group}) {
                        $owner_group = "'$args->{owner}:$args->{group}'";
                    } elsif ($args->{owner}) {
                        $owner_group = "'$args->{owner}'";
                    } elsif ($args->{group}) {
                        $ssh->system("$sudo chgrp '$args->{group}' '$path'");
                    }
                    $ssh->system("$sudo chown $owner_group '$path'") if $owner_group;
                }
                $ssh->system("$sudo chmod '$args->{mode}' '$path'") if $args->{mode};
                
                return { changed => 1 };
            }
        }
        
        if ($state eq 'absent') {
            # Remove arquivo/diretório
            my $check_cmd = "if [ -e '$path' ]; then echo 'EXISTS'; else echo 'NOT_EXISTS'; fi";
            my $exists = $ssh->capture($check_cmd);
            chomp $exists;
            return { changed => 0 } unless $exists eq 'EXISTS';
            
            $ssh->system("$sudo rm -rf '$path'");
            return { changed => 1 };
        }
        
        if ($state eq 'file') {
            # Para arquivo regular, verifica se existe
            my $check_cmd = "if [ -f '$path' ]; then echo 'EXISTS'; else echo 'NOT_EXISTS'; fi";
            my $exists = $ssh->capture($check_cmd);
            chomp $exists;
            
            if ($exists eq 'EXISTS') {
                # Arquivo existe, verifica permissões
                my $changed = 0;
                
                if ($args->{owner}) {
                    my $current_owner = $ssh->capture("ls -ld '$path' | awk '{print \$3}'");
                    chomp $current_owner;
                    if ($current_owner ne $args->{owner}) {
                        $ssh->system("$sudo chown '$args->{owner}' '$path'");
                        $changed = 1;
                    }
                }
                
                if ($args->{group}) {
                    my $current_group = $ssh->capture("ls -ld '$path' | awk '{print \$4}'");
                    chomp $current_group;
                    if ($current_group ne $args->{group}) {
                        $ssh->system("$sudo chgrp '$args->{group}' '$path'");
                        $changed = 1;
                    }
                }
                
                if ($args->{mode}) {
                    my $current_mode_str = $ssh->capture("ls -ld '$path' | awk '{print \$1}'");
                    chomp $current_mode_str;





                    my $current_mode = '';
                    if ($current_mode_str =~ /^-(...)(...)(...)/) {
                        my ($u, $g, $o) = ($1, $2, $3);
                        # Converte cada parte individualmente
                        my $u_num = ($u =~ /r/ ? 4 : 0) + ($u =~ /w/ ? 2 : 0) + ($u =~ /x/ ? 1 : 0);
                        my $g_num = ($g =~ /r/ ? 4 : 0) + ($g =~ /w/ ? 2 : 0) + ($g =~ /x/ ? 1 : 0);
                        my $o_num = ($o =~ /r/ ? 4 : 0) + ($o =~ /w/ ? 2 : 0) + ($o =~ /x/ ? 1 : 0);
                        $current_mode = sprintf("%d%d%d", $u_num, $g_num, $o_num);
                    }







                    if ($current_mode ne $args->{mode}) {
                        $ssh->system("$sudo chmod '$args->{mode}' '$path'");
                        $changed = 1;
                    }
                }
                
                return { changed => $changed };
            } else {
                # Cria arquivo vazio
                $ssh->system("$sudo touch '$path'");
                
                # Configura permissões
                if ($args->{owner} || $args->{group}) {
                    my $owner_group = '';
                    if ($args->{owner} && $args->{group}) {
                        $owner_group = "'$args->{owner}:$args->{group}'";
                    } elsif ($args->{owner}) {
                        $owner_group = "'$args->{owner}'";
                    } elsif ($args->{group}) {
                        $ssh->system("$sudo chgrp '$args->{group}' '$path'");
                    }
                    $ssh->system("$sudo chown $owner_group '$path'") if $owner_group;
                }
                $ssh->system("$sudo chmod '$args->{mode}' '$path'") if $args->{mode};
                
                return { changed => 1 };
            }
        }
        
        if ($state eq 'touch') {
            # Apenas atualiza timestamp, cria se não existir
            $ssh->system("$sudo touch '$path'");
            return { changed => 1 };
        }
        
        return { changed => 0, error => "Estado '$state' não suportado para file" };
    }

    return { changed => 0, error => "Módulo $mod não implementado" };
}
1;
