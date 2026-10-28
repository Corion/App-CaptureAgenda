#!/usr/bin/perl
#
# t/import-toast.t -- import results must surface as a toast on /results
#
# /import redirects back to /results carrying imported=/failed= counts;
# the results page renders a Bootstrap toast when a count is nonzero.
# Uses the cached-ICS branch of /extract to get a done request without
# talking to z.ai: seed the upload dir with <md5>.ics + <md5>.0.png and
# post the same image.
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
use Digest::MD5 'md5_hex';

my $dir     = dirname(__FILE__);
my $tmp     = File::Temp->newdir;
my $uploads = path( $tmp->dirname );

my $bytes = "toast png bytes";
my $id    = md5_hex($bytes);
my $ics   = join "\r\n",
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//test//EN',
    'BEGIN:VEVENT', 'UID:toast-test-1@example.com', 'DTSTAMP:20261007T120000Z',
    'DTSTART;VALUE=DATE:20261101', 'SUMMARY:Toastkonzert',
    'END:VEVENT', 'END:VCALENDAR', '';
$uploads->child("$id.ics")->spew($ics);
$uploads->child("$id.0.png")->spurt($bytes);

$ENV{ZAI_API_KEY}               = 'test-key';
$ENV{CAPTURE_AGENDA_UPLOAD_DIR} = $uploads->to_string;

# __DATA__ splice (see t/extract-error.t for the full story)
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

subtest 'request is done via the cached branch' => sub {
    $t->post_ok( '/extract', form => { images => { file => $uploads->child("$id.0.png")->to_string, 'Content-Type' => 'image/png' } } );
    $t->status_is(302);
    $t->get_ok("/results?request-id=$id")->status_is(200);
    like( $t->tx->res->body, qr/- done/, 'cached request renders as done' );
};

subtest 'counts render a toast' => sub {
    $t->get_ok("/results?request-id=$id&imported=2&failed=1")->status_is(200);
    like(   $t->tx->res->body, qr{id="import-toast"},   'toast element present' );
    like(   $t->tx->res->body, qr{Imported 2},          'imported count shown' );
    like(   $t->tx->res->body, qr{1 failed},            'failure count shown' );
};

subtest 'no toast without counts' => sub {
    $t->get_ok("/results?request-id=$id")->status_is(200);
    unlike( $t->tx->res->body, qr{id="import-toast"}, 'no toast without params' );

    $t->get_ok("/results?request-id=$id&imported=0&failed=0")->status_is(200);
    unlike( $t->tx->res->body, qr{id="import-toast"}, 'no toast for zero counts' );
};

done_testing();
