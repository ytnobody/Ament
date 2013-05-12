#!perl

use strict;
use warnings;
use utf8;
use Ament;
use Ament::Script;
use Capture::Tiny qw/capture/;

use t::Util;
use Test::More;

subtest 'Show version' => sub {
    my $test_showing_version = sub {
        my @args  = @_;
        my $ament = Ament::Script->new(@args);
        my ($got) = capture { $ament->execute() };
        chomp $got;
        is $got, $Ament::VERSION;
    };

    subtest 'by `-v`' => sub {
        $test_showing_version->( ('-v') );
    };
    subtest 'by `--version`' => sub {
        $test_showing_version->( ('--version') );
    };
};

subtest 'Show help' => sub {
    my $test_showing_help = sub {
        my (@args) = @_;
        my $ament = Ament::Script->new(@args);
        my ($got) = capture { $ament->execute() };
        like $got, qr/Usage: ament COMMAND \[\.\.\.\]/;
    };

    subtest 'by empty' => sub {
        $test_showing_help->();
    };
    subtest 'by `help`' => sub {
        $test_showing_help->('help');
    };
};

subtest 'Fetch and show boxes that failure testing' => sub {
    my $guard = t::Util::setup_mock_downloader();

    my $fetch_failures = sub {
        my @args  = @_;
        my $ament = Ament::Script->new(@args);
        my ($got) = capture { $ament->execute() };
        return $got;
    };

    subtest 'not specify version' => sub {
        my $got = $fetch_failures->(('failures', 'Ament::Test::Sandbox'));
        like $got, qr!0\.01 perl-5\.8\.9 OpenBSD OpenBSD.i386-openbsd-thread-multi\n0\.02 perl-5\.10\.0 GNU/Linux x86_64-linux-thread-multi!;
    };

    subtest 'specify version by v0.01' => sub {
        my $got = $fetch_failures->(('failures', 'Ament::Test::Sandbox', '0.01'));
        like $got, qr/0\.01 perl-5\.8\.9 OpenBSD OpenBSD.i386-openbsd-thread-multi/;
    };
};

subtest 'Detect illegal command' => sub {
    my $ament = Ament::Script->new(('ILLEGAL_COMMAND'));
    eval { $ament->execute() };
    like $@, qr/! Unknown command: 'ILLEGAL_COMMAND'/;
};

done_testing;
