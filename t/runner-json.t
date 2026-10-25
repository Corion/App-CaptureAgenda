#!/usr/bin/perl
#
# t/runner-json.t -- ZAI::Runner must convert at the HTTP boundary:
#   request  body : UTF-8 *bytes* (unflagged, no wide-char warnings)
#   response body : character strings, regardless of how the API
#                   serialized them (raw UTF-8 or \uXXXX escapes)
#   invalid JSON  : (undef, $err), not a die
#
use strict;
use warnings;
use utf8;

use File::Basename;
use lib dirname(__FILE__) . '/../lib';

use Test::More;
use JSON::PP ();
use Encode 'decode';

use ZAI::Runner;

my @warn;
local $SIG{__WARN__} = sub { push @warn, $_[0] };

my $runner = ZAI::Runner->new(
    api_key => 'test-key',
    model   => 'test-model',
    prompt  => 'base prompt',
);

# "Könzert" + top-hat emoji (U+1F3A9): covers BMP (U+00F6) and
# astral-plane (4-byte UTF-8) characters
my $instr = decode( 'UTF-8', "Nur K\xC3\xB6nzert, keine Filme \xF0\x9F\x8E\xA9" );

subtest 'request body is UTF-8 bytes' => sub {
    @warn = ();
    my ( $url, $opts ) = $runner->build_prompt_request(
        additional_instructions => $instr,
    );
    ok( defined $url && $url =~ m{/chat/completions$}, 'endpoint URL' );

    my $body = $opts->{content};
    ok( defined $body && !ref $body, 'body is a plain scalar' );
    ok( !utf8::is_utf8($body), 'body is a byte string, not wide chars' );
    like( $body, qr/K\xC3\xB6nzert/, 'body contains UTF-8 bytes for o-umlaut (0xC3 0xB6)' );
    ok( index( $body, "\xF0\x9F\x8E\xA9" ) >= 0, 'body contains 4-byte UTF-8 sequence for emoji' );
    is_deeply( \@warn, [], 'no warnings while encoding' );

    # A strict UTF-8 JSON decoder must accept the body and restore the chars
    my $rt      = JSON::PP->new->utf8->decode($body);
    my ($text)  = grep { $_->{type} eq 'text' } $rt->{messages}[0]{content}->@*;
    is( $text->{text},
        "base prompt\n\nAdditional user instructions:\n$instr\n",
        'characters survive the byte round-trip' );
};

subtest 'decode_response returns uniform character strings' => sub {
    my $payload = { choices => [ { message => { content => $instr } } ] };
    my $raw = JSON::PP->new->utf8->encode($payload);    # API emits raw UTF-8
    my $esc = JSON::PP->new->ascii->encode($payload);   # API emits \uXXXX

    for my $body ( [ raw_utf8 => $raw ], [ u_escapes => $esc ] ) {
        my ( $label, $bytes ) = @$body;
        @warn = ();
        my ( $res, $err ) = $runner->decode_response($bytes);
        is( $err, undef, "$label: no error" ) or diag explain $err;
        my $content = $res->{choices}[0]{message}{content};
        ok( utf8::is_utf8($content), "$label: content is a character string" );
        is( $content, $instr, "$label: content equals the expected characters" );
        is_deeply( \@warn, [], "$label: no warnings while decoding" );
    }
};

subtest 'decode_response honours the error contract' => sub {
    my ( $res, $err );
    my $died = !eval { ( $res, $err ) = $runner->decode_response('<html>502 Bad Gateway</html>'); 1 };
    ok( !$died, 'returns instead of dying' ) or diag "died with: $@";
    is( $res, undef, 'no data for invalid JSON' );
    like( $err, qr/\S/, 'an error message is returned' );
};

done_testing();
