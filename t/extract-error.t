#!/usr/bin/perl
#
# t/extract-error.t -- /extract must surface API/JSON errors to the user
#
# The app's z.ai request runs asynchronously; when it fails (HTTP error,
# undecodable body, empty content) the results page must stop polling and
# show the failure instead of silently looking "done" (or exploding).
#
# A fake z.ai endpoint runs in-process on the loopback interface and
# serves one canned response per request, in order:
#   1. 500 + JSON error body
#   2. 200 + non-JSON body
#   3. 200 + valid JSON with empty content
#   4. 200 + valid JSON with a real VCALENDAR (happy-path regression guard)
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
use Mojo::IOLoop;
use Mojolicious ();
use Mojo::Server::Daemon;
use Digest::MD5 'md5_hex';

my $dir     = dirname(__FILE__);
my $tmp     = File::Temp->newdir;
my $uploads = path( $tmp->dirname );

my $ics = join "\r\n",
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//test//EN',
    'BEGIN:VEVENT', 'UID:err-test-1@example.com', 'DTSTAMP:20261007T120000Z',
    'DTSTART;VALUE=DATE:20261010', 'SUMMARY:Testkonzert',
    'END:VEVENT', 'END:VCALENDAR', '';

my @responses = (
    { status => 500, json => { error => { message => 'Internal woo' } } },
    { status => 200, text => 'this is not json at all' },
    { status => 200, json => { choices => [ { message => { content => '' } } ] } },
    { status => 200, json => { choices => [ { message => { content => $ics } } ] } },
);

my $calls;
my $fake = Mojolicious->new;
$fake->log->level('fatal');
$fake->routes->post(
    '/chat/completions' => sub {
        my $c    = shift;
        my $resp = $responses[ $calls++ ] // $responses[-1];
        return $resp->{json}
            ? $c->render( json => $resp->{json}, status => $resp->{status} )
            : $c->render( text => $resp->{text}, status => $resp->{status} );
    }
);

my $daemon = Mojo::Server::Daemon->new(
    app    => $fake,
    listen => ['http://127.0.0.1'],
    silent => 1
);
$daemon->start;
my $port = $daemon->ports->[0];

# Load the app pointed at the fake endpoint
$ENV{ZAI_API_KEY}              = 'test-key';
$ENV{ZAI_API_BASE}             = "http://127.0.0.1:$port";
$ENV{CAPTURE_AGENDA_UPLOAD_DIR} = $uploads->to_string;
# The app keeps its templates in the script's __DATA__ section and reads
# them via package main -- but this test file owns main and has no
# __DATA__, so requiring the app never populates main::DATA and every
# template render fails. Splice the section in through a temp file
# (Mojo::Loader requires a real filehandle).
{
    my $script = path( abs_path("$dir/../scripts/capture-agenda.pl") )->slurp;
    my ($data) = $script =~ /^__DATA__\r?\n(.*)/ms
        or die "no __DATA__ section found in app script";
    my $tmpdata = File::Temp->new;
    print {$tmpdata} "__DATA__\n", $data;
    close $tmpdata;
    open my $DATA, '<', $tmpdata->filename or die "Can't open DATA splice: $!";
    *main::DATA = $DATA;
}

require( abs_path("$dir/../scripts/capture-agenda.pl") );

my $t = Test::Mojo->new( app() );

# Upload one distinct image; returns the request id the app will derive
sub post_image {
    my ($bytes) = @_;
    my $img = $uploads->child( 'img-' . md5_hex($bytes) . '.png' );
    $img->spurt($bytes);
    $t->post_ok( '/extract', form => { images => { file => "$img", 'Content-Type' => 'image/png' } } );
    $t->status_is(302);
    return md5_hex($bytes);
}

# Give the background promise a slice of loop time between polls.
# A 500 means the results page crashed (unrenderable record) -- report
# that instead of looping until the deadline.
sub result_state {
    my ($id) = @_;
    my $deadline = time + 10;
    while ( time < $deadline ) {
        Mojo::IOLoop->timer( 0.05 => sub { Mojo::IOLoop->stop } );
        Mojo::IOLoop->start;
        $t->get_ok("/results?request-id=$id");
        return ( 'crashed', $t->tx->res->body ) if $t->tx->res->code == 500;
        my ($state) = $t->tx->res->body =~ /- (done|failed|in progress)/;
        return ( $state, $t->tx->res->body )
            if defined $state && $state ne 'in progress';
    }
    return ( undef, 'timed out waiting for the request to finish' );
}

my $id1 = post_image("scenario one png bytes");
my ( $state1, $body1 ) = result_state($id1);
is( $state1, 'failed', 'HTTP 500 surfaces as "failed"' );
like( $body1, qr/Extraction failed/, 'error notice shown' );
like( $body1, qr/Internal woo/,      'API error detail shown' );

my $id2 = post_image("scenario two png bytes");
my ( $state2, $body2 ) = result_state($id2);
is( $state2, 'failed', 'undecodable body surfaces as "failed"' );
like( $body2, qr/Extraction failed/,    'error notice shown' );
like( $body2, qr/JSON decode error/i,   'decode error shown' );

my $id3 = post_image("scenario three png bytes");
my ( $state3, $body3 ) = result_state($id3);
is( $state3, 'failed', 'empty content surfaces as "failed"' );
like( $body3, qr/Extraction failed/, 'error notice shown' );
like( $body3, qr/empty response/i,   'empty-response reason shown' );

my $id4 = post_image("scenario four png bytes");
my ( $state4, $body4 ) = result_state($id4);
is( $state4, 'done', 'valid response still completes' );
unlike( $body4, qr/Extraction failed/, 'no error notice on success' );
ok( -f $uploads->child("$id4.ics"), 'ics written to disk' );
like( $uploads->child("$id4.ics")->slurp, qr/Testkonzert/, 'ics has the event' );

subtest 'htmx attributes' => sub {
    # list/raw fragments must swap into the calendar div; "next div"
    # resolves to the anchor's next *sibling*, of which there is none
    # inside the <li>
    like(   $body4, qr{hx-target="#calendar-content"}, 'list/raw links target #calendar-content' );
    unlike( $body4, qr{hx-target="next div"},           'no sibling-relative target left' );

    # the upload form posts via htmx and gets a redirect to the results
    # page; the whole body must be the swap target, not the form itself
    $t->get_ok('/index.html')->status_is(200);
    like( $t->tx->res->body, qr{hx-target="#body"}, 'upload form targets #body' );
};

done_testing();
