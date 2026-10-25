#!/usr/bin/perl
#
# t/ics-download.t -- the /ics/<request-id>.ics download route
#
# The results page links to /ics/$request_id.ics; the route must serve the
# stored calendar file (text/calendar, attachment) from the upload dir, and
# must 404 for unknown or malformed ids.
#
use strict;
use warnings;

use File::Basename;
use lib dirname(__FILE__) . '/../lib';

use Test::More;
use Test::Mojo;
use File::Temp ();
use Cwd 'abs_path';
use Mojo::File 'path';

my $id      = '0123456789abcdef0123456789abcdef';
my $fixture = path( dirname(__FILE__) . '/data/umlauts.ics' )->slurp;
my $tmp     = File::Temp->newdir;
path( $tmp->dirname )->child("$id.ics")->spurt($fixture);

# Must be set before the app is loaded (require is a runtime statement,
# so plain top-to-bottom ordering works; no BEGIN needed)
$ENV{ZAI_API_KEY} = 'test-key';                # ZAI::Runner requires one at load
$ENV{CAPTURE_AGENDA_UPLOAD_DIR} = $tmp->dirname;

require( abs_path( dirname(__FILE__) . '/../scripts/capture-agenda.pl' ) );
my $t = Test::Mojo->new( app() );

subtest 'serves a stored request as text/calendar' => sub {
    $t->get_ok("/ics/$id.ics")
      ->status_is(200)
      ->header_like( 'Content-Type'        => qr{text/calendar} )
      ->header_like( 'Content-Disposition' => qr{attachment} )
      ->header_like( 'Content-Disposition' => qr{\Q$id.ics\E} );

    # ->body: raw bytes; content_is would compare the charset-decoded text
    is( $t->tx->res->body, $fixture, 'body is the stored .ics, byte for byte' );
};

subtest '404s for unknown or malformed ids' => sub {
    my $unknown = 'f' x 32;
    $t->get_ok("/ics/$unknown.ics")->status_is(404, 'well-formed but unknown id');

    $t->get_ok('/ics/garbage.ics')->status_is(404, 'non-hex id');
    $t->get_ok('/ics/short.ics')->status_is(404, 'too-short id');
    $t->get_ok("/ics/@{[ 'a' x 33 ]}.ics")->status_is(404, 'too-long id');

    # encoded traversal must not escape the placeholder match
    $t->get_ok('/ics/..%2F..%2Fetc%2Fpasswd.ics')->status_is(404, 'path traversal');
    $t->get_ok("/ics/$id.txt")->status_is(404, 'wrong extension');
};

done_testing();
