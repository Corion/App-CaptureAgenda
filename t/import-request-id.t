#!/usr/bin/perl
#
# t/import-request-id.t -- /import must reject malformed request ids
#
# The request id is used to build a file path; anything that is not
# exactly 32 lowercase hex chars (an md5_hex) must be rejected with 404
# BEFORE any file or CalDAV access happens.
#
use strict;
use warnings;

use File::Basename;
use lib dirname(__FILE__) . '/../lib';

use Test::More;
use Test::Mojo;
use Cwd 'abs_path';
use File::Temp ();
use Mojo::File 'path';

my $dir = dirname(__FILE__);
my $tmp = File::Temp->newdir;

$ENV{ZAI_API_KEY}              = 'test-key';
$ENV{CAPTURE_AGENDA_UPLOAD_DIR} = path( $tmp->dirname )->to_string;

require( abs_path("$dir/../scripts/capture-agenda.pl") );
my $t = Test::Mojo->new( app() );

subtest 'malformed request ids are rejected with 404' => sub {
    my @bad = (
        [ garbage    => 'garbage' ],
        [ too_short  => 'a' x 31 ],
        [ too_long   => 'a' x 33 ],
        [ uppercase  => uc '0123456789abcdef0123456789abcdef' ],
        [ traversal  => '../../etc/passwd' ],
        [ newline    => "0123456789abcdef0123456789abcde\n" ],
        [ suffix     => "0123456789abcdef0123456789abcdef.ics" ],
        [ null_byte  => "0123456789abcdef0123456789abcde\0" ],
    );
    for my $case (@bad) {
        my ( $label, $id ) = @$case;
        $t->post_ok( '/import', form => { 'request-id' => $id, import => 'x' } );
        $t->status_is( 404, "rejects $label" );
    }
};

subtest 'a well-formed id is not rejected by the format check' => sub {
    # 32 lowercase hex passes validation. The request then fails later
    # (this test env has no CalDAV config), but crucially NOT with 404.
    my $id = 'f' x 32;
    $t->post_ok( '/import', form => { 'request-id' => $id, import => 'x' } );
    $t->status_isnt(404);
};

done_testing();
