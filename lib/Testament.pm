package Testament;
use 5.008005;
use strict;
use warnings;
use Testament::Setup;
use Testament::OSList;
use Testament::Virt;
use Testament::Virt::Vagrant;
use Testament::BoxUtils;
use Testament::Util;
use Testament::URLFetcher;
use Testament::Git;
use Testament::Constants qw(
    CHEF_INSTALLER_URL
    RBENV_REPO
    RUBYBUILDER_REPO
    SPAWN_TIMEOUT
);
use File::Spec;
use Expect;
use Data::Dumper::Concise;

our $VERSION = "0.01";

my $config = Testament::OSList->load;

sub setup {
    my ( $class, $os_text, $os_version, $arch ) = @_;

    if ($os_text eq 'GNU_Linux') {
        # TODO It's all right?
        ($os_version) = $os_version =~ m/(.*?-.+?)(?:-.*)?/;
    }

    if ($Testament::OSList::VM_BACKEND =~ /^vagrant$/) {
        my $vagrant = Testament::Virt::Vagrant->new( os_text => $os_text, os_version => $os_version, arch => $arch );
        $vagrant->install_box();
        return 1;
    }

    my $setup = Testament::Setup->new( os_text => $os_text, os_version => $os_version, arch => $arch );
    my $virt = $setup->do_setup;
    die sprintf('could not setup %s', $os_text) unless $virt;
    my $identify_str = Testament::BoxUtils->box_identity($os_text, $os_version, $arch);
    $config->{$identify_str} = $virt->as_hashref;
    Testament::OSList->save($config);
    return 1;
}

sub boot {
    my ( $class, $os_text, $os_version, $arch ) = @_;
    my $identify_str = Testament::BoxUtils->box_identity($os_text, $os_version, $arch);
    my $box_conf = $config->{$identify_str};
    die sprintf('could not find config for %s', $identify_str) unless $box_conf;
    $box_conf->{id} = $identify_str;
    my $virt = Testament::Virt->new(%$box_conf);
    $virt->boot();
}

sub list {
    my ( $class ) = @_;
    my @running = Testament::BoxUtils->running_boxes;
    my $max_l = (sort {$b <=> $a} map {length($_)} keys %$config)[0];
    $max_l ||= 6; # NOTE <= Length of index
    printf "% 6s % ".$max_l."s % 8s % 8s % 8s % 8s\n", 'KEY', 'BOX-ID', 'STATUS', 'CPU', 'RAM', 'SSH-PORT';
    my @boxes = Testament::OSList->boxes;
    for my $i (0..$#boxes) {
        my $id = $boxes[$i];
        my $vm = $config->{$id};
        my $status = scalar(grep { $_->{cmd} =~ /$id/ } @running) > 0 ? 'RUNNING' : '---';
        printf "% 6s % ".$max_l."s % 8s % 8s % 6sMB % 8s\n", $i+1, $id, $status, $vm->{core} || 1, $vm->{ram}, $vm->{ssh_port};
    }
}

sub exec {
    my ( $class, $os_text, $os_version, $arch, $cmd ) = @_;
    my $identify_str = Testament::BoxUtils->box_identity($os_text, $os_version, $arch);
    die sprintf("%s is not running", $identify_str) unless Testament::BoxUtils->is_box_running($identify_str);
    my $box_conf = $config->{$identify_str};
    $box_conf->{id} = $identify_str;
    my @cmdlist = ('ssh', '-p', $box_conf->{ssh_port}, 'root@127.0.0.1');
    if (defined $cmd) {
        $cmd = ". ~/.bash_profile; ( $cmd )";
        push @cmdlist, $cmd;
    }
    my $spawn = Expect->spawn(@cmdlist);
    my $pass = 0;
    $spawn->expect(SPAWN_TIMEOUT,
        [qr/\(yes\/no\)/ => sub {
            shift->send("yes\n");
        } ],
        [qr/sword/ => sub {
            shift->send("testament\n");
            $pass = 1;
        } ],
    );
    unless ($pass) {
        $spawn->expect(SPAWN_TIMEOUT,
            [qr/sword/ => sub {
                shift->send("testament\n");
            } ],
        );
    };
    $spawn->interact;
    $spawn->soft_close;
}

sub enter {
    my ( $class, $os_text, $os_version, $arch ) = @_;
    $class->exec($os_text, $os_version, $arch);
}

sub kill {
    my ( $class, $os_text, $os_version, $arch ) = @_;
    my $identify_str = Testament::BoxUtils->box_identity($os_text, $os_version, $arch);
    my ( $proc ) = Testament::BoxUtils->is_box_running($identify_str);
    die sprintf("%s is not running", $identify_str) unless $proc;
    kill(15, $proc->{pid}); ### SIGTERM
}

sub delete {
    my ( $class, $os_text, $os_version, $arch ) = @_;
    my $identify_str = Testament::BoxUtils->box_identity($os_text, $os_version, $arch);
    my ( $proc ) = Testament::BoxUtils->is_box_running($identify_str);
    if ( $proc ) {
        if ( Testament::Util->confirm("box '$identify_str' is running. Do you kill it ?", 'n') =~ /^y/i ) {
            $class->kill($os_text, $os_version, $arch);
        }
        else {
            die "aborted";
        }
    }
    my $vmdir = Testament::BoxUtils->vmdir($identify_str);
    if ( Testament::Util->confirm("really want to remove bot '$identify_str' ?", 'n') =~ /^y/i ) {
        system("rm -rfv $vmdir");
        delete $config->{$identify_str};
        Testament::OSList->save($config);
    }
}

sub file_transfer {
    my ( $class, $os_text, $os_version, $arch, $src, $dst, $mode, @opts ) = @_;
    my $identify_str = Testament::BoxUtils->box_identity($os_text, $os_version, $arch);
    die sprintf("%s is not running", $identify_str) unless Testament::BoxUtils->is_box_running($identify_str);
    my $box_conf = $config->{$identify_str};
    my @cmdlist = ('scp', '-P', $box_conf->{ssh_port});
    push @cmdlist, @opts if @opts;
    push @cmdlist, $mode eq 'put' ? ($src, 'root@127.0.0.1:'.$dst) : ('root@127.0.0.1:'.$dst, $src);
    my $spawn = Expect->spawn(@cmdlist);
    $spawn->expect(SPAWN_TIMEOUT,
        ["(yes/no)?" => sub {
            shift->send("yes\n");
        } ],
    );
    $spawn->expect(SPAWN_TIMEOUT,
        [qr/sword/ => sub {
            shift->send("testament\n");
        } ],
    );
    $spawn->interact;
    $spawn->soft_close;
}

sub put {
    my ( $class, $os_text, $os_version, $arch, $src, $dst, @opts ) = @_;
    $class->file_transfer($os_text, $os_version, $arch, $src, $dst, 'put', @opts);
}

sub get {
    my ( $class, $os_text, $os_version, $arch, $src, $dst, @opts ) = @_;
    $class->file_transfer($os_text, $os_version, $arch, $src, $dst, 'get', @opts);
}

sub install_perl {
    my ( $class, $os_text, $os_version, $arch, $perl_version ) = @_;
    $class->exec($os_text, $os_version, $arch, "( plenv || curl -L http://is.gd/plenvsetup | sh ); plenv install $perl_version && plenv global $perl_version && plenv install-cpanm");
}

sub box_config {
    my ( $class, $os_text, $os_version, $arch, $key, $val ) = @_;
    my $identify_str = Testament::BoxUtils->box_identity($os_text, $os_version, $arch);
    unless ($key) {
        print Dumper($config->{$identify_str});
        return;
    }
    unless (defined $val) {
        printf "%s\n", $config->{$identify_str}{$key};
    }
    else {
        $config->{$identify_str}{$key} = $val;
    }
    Testament::OSList->save($config);
}

sub backup {
    my ( $class, $os_text, $os_version, $arch, $subname ) = @_;
    $class->load_virt($os_text, $os_version, $arch)->backup($subname);
}

sub backup_list {
    my ( $class, $os_text, $os_version, $arch ) = @_;
    $class->load_virt($os_text, $os_version, $arch)->backup_list;
}

sub purge_backup {
    my ( $class, $os_text, $os_version, $arch, $subname ) = @_;
    $class->load_virt($os_text, $os_version, $arch)->purge_backup($subname);
}

sub restore {
    my ( $class, $os_text, $os_version, $arch, $subname ) = @_;
    $class->load_virt($os_text, $os_version, $arch)->restore($subname);
}

sub load_virt {
    my ( $class, $os_text, $os_version, $arch ) = @_;
    my $identify_str = Testament::BoxUtils->box_identity($os_text, $os_version, $arch);
    my $vmdir = Testament::BoxUtils->vmdir($identify_str);
    my $box_conf = $config->{$identify_str};
    Testament::Virt->new(%$box_conf);
}

1;
__END__

=encoding utf-8

=head1 NAME

Testament - TEST AssignMENT

=begin html

<img src="https://travis-ci.org/ytnobody/Testament.png?branch=master">

=end html

=head1 SYNOPSIS

To show failure report for your module,

    $ testament failures Your::Module
    0.05 perl-5.12.1 OpenBSD 5.1 OpenBSD.amd64-openbsd-thread-multi
    0.05 perl-5.10.0 OpenBSD 5.1 OpenBSD.i386-openbsd
    0.05 perl-5.14.4 FreeBSD 9.1-release amd64-freebsd-thread-multi

And, you can create a new box

    $ testament create OpenBSD 5.1 OpenBSD.i386-openbsd

To show boxes-list,

    $ testament list
     KEY                             BOX-ID   STATUS      RAM SSH-PORT
       1 OpenBSD::5.1::OpenBSD.i386-openbsd      ---    256MB    50954

To boot a exists box,

    $ testament boot OpenBSD 5.1 OpenBSD.i386-openbsd
    ### or
    $ testament boot 1

=head1 DESCRIPTION

Testament is a testing environment builder tool.

=head1 USAGE

  testament subcommand [arguments]

=head2 subcommand

=over 4

=item boot ([boxkey] or [os-test os-version architecture]) : boot-up specified box

=item create ([boxkey] or [os-test os-version architecture]) : create environment

=item put ([boxkey] or [os-test os-version architecture source-file dest-path]) : put file into specified box

=item help ([boxkey] or [(no arguments)]) : show this help

=item failures ([boxkey] or [cpan-module-name]) : fetch and show boxes that failures testing

=item box_config ([os-test os-version architecture key=value]) : config parameter of specified box

=item get ([boxkey] or [os-test os-version architecture source-file dest-path]) : get file from specified box

=item kill ([boxkey] or [os-test os-version architecture]) : kill specified box

=item install_perl ([os-test os-version architecture version]) : setup specified version perl into specified box

=item list [(no arguments)] : show boxes in your machine

=item install ([boxkey] or [os-test os-version architecture]) : alias for create

=item enter ([boxkey] or [os-test os-version architecture]) : enter into box

=item version [(no arguments)] : show testament version

=item delete ([boxkey] or [os-test os-version architecture]) : delete specified box

=item exec ([boxkey] or [os-test os-version architecture commands...]) : execute command into box

=item backup_list ([os-text os-version architecture]) : show backup list of specified box

=item backup ([os-text os-version architecture backup_name]) : backup specified box image

=item restore ([os-text os-version architecture backup_name]) : restore from specified backup image

=item purge_backup ([os-text os-version architecture backup_name]) : purge specified backup image

=back

=head1 LICENSE

Copyright (C) ytnobody.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

ytnobody E<lt>ytnobody aaaaatttttt gmailE<gt>

moznion

=cut

