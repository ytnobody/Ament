package Testament::Virt::QEMU;
use strict;
use warnings;
use File::Which 'which';
use Log::Minimal;

sub boot {
    my ($class, $virt) = @_;

    my $arch = $virt->arch;
    $arch =~ s/amd64/x86_64/;
    my $bin = which('qemu-system-'.$arch);
    my @options = (
        '-m'       => $virt->ram,
        '-hda'     => $virt->hda,
        '-redir'   => sprintf('tcp:%d::22', $virt->ssh_port),
    );
    if ( $virt->cdrom ) {
        push @options, ('-cdrom' => $virt->cdrom);
        push @options, ('-boot'  => 'd');
    }
    my $cmd = join(' ', $bin, @options);
    `$cmd`;
}

sub create_image {
    my ($class, $path, $size) = @_;
    my $bin = which('qemu-img');
    my @options = (qw(create -f qcow2), $path, $size);
    my $cmd = sprintf('%s %s', $bin, join(' ', @options));
    `$cmd`;
}

1;

