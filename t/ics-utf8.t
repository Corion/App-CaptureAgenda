#!/usr/bin/perl
#
# t/ics-utf8.t -- on-disk UTF-8 handling of .ics files, mirroring what
# capture-agenda.pl does:
#
#   * saved files are UTF-8 bytes with CRLF endings (RFC 5545)
#   * path($file)->slurp('UTF-8') yields character strings
#   * path($file)->spew($chars, 'UTF-8') round-trips byte-identically,
#     without wide-character warnings
#   * Text::JSCalendar->vcalendarToEvents($chars) (the webapp's parse
#     call, cached branch) yields correct titles as characters
#
use strict;
use warnings;
use utf8;

use File::Basename;
use Test::More;
use Mojo::File 'path';
use File::Temp ();
use Encode 'decode';

BEGIN {
    eval { require Text::JSCalendar; 1 }
        or plan skip_all => 'Text::JSCalendar not installed yet';
}

my $dir = dirname(__FILE__) . '/data';

my %fixture = (
    'umlauts.ics' => {
        bytes => "\xC3\x9F",              # sharp-s as UTF-8
        titles => [ 'Au' . chr(0xDF) . 'er Kontrolle',
                    'Fr' . chr(0xFC) . 'hst' . chr(0xFC) . 'ck bei B' . chr(0xE4) . 'cker Krause' ],
    },
    'emoji.ics' => {
        bytes => "\xF0\x9F\x8E",          # lead bytes of a 4-byte sequence
        titles => [ 'Zirkus ' . chr(0x1F3AA) . ' in der Stadt' ],   # U+1F3AA circus tent
    },
);

my @warn;
local $SIG{__WARN__} = sub { push @warn, $_[0] };

for my $name ( sort keys %fixture ) {
    my $marker = $fixture{$name}{bytes};
    my @titles = $fixture{$name}{titles}->@*;

    subtest "$name: bytes on disk" => sub {
        my $bytes = do {
            open my $fh, '<:raw', "$dir/$name" or die "Cannot read $dir/$name: $!";
            local $/; <$fh>;
        };
        ok( index( $bytes, $marker ) >= 0, 'non-ASCII stored as UTF-8 bytes' );
        like( $bytes, qr/\r\n/, 'CRLF line endings' );
        unlike( $bytes, qr/(?<!\r)\n/, 'no bare LF' );
        ok( eval { decode( 'UTF-8', $bytes, 1 ); 1 }, 'file is valid UTF-8' ) or diag $@;
    };

    subtest "$name: slurp('UTF-8') returns characters" => sub {
        my $chars = path("$dir/$name")->slurp('UTF-8');
        ok( utf8::is_utf8($chars), 'slurped string is character-string (flagged)' );
        unlike( $chars, qr/\x{FFFD}/, 'no replacement characters' );
    };

    subtest "$name: spew('UTF-8') round-trips" => sub {
        my $orig_bytes = path("$dir/$name")->slurp;
        my $chars      = path("$dir/$name")->slurp('UTF-8');

        my $tmp = File::Temp->new( UNLINK => 1, SUFFIX => '.ics' );
        my $out = path( $tmp->filename );

        @warn = ();
        $out->spew( $chars, 'UTF-8' );
        is_deeply( \@warn, [], 'no wide-character warnings on spew' );

        is( $out->slurp, $orig_bytes, 'round-trip is byte-identical' );
        is( $out->slurp('UTF-8'), $chars, 'round-trip is character-identical' );
    };

    subtest "$name: Text::JSCalendar parses characters" => sub {
        my $chars = path("$dir/$name")->slurp('UTF-8');

        @warn = ();
        my @events = Text::JSCalendar->new()->vcalendarToEvents($chars);
        is( scalar @events, scalar @titles, 'one event per VEVENT' );
        is_deeply( \@warn, [], 'no warnings while parsing' );

        my @sorted = sort { $a->{start} cmp $b->{start} } @events;
        for my $i ( 0 .. $#titles ) {
            is( $sorted[$i]{title}, $titles[$i], "title $i is the expected character string" );
            unlike( $sorted[$i]{title} // '', qr/\x{FFFD}/, "title $i has no replacement chars" );
        }
        ok( utf8::is_utf8( $sorted[0]{title} ), 'title is a character string' );
    };
}

done_testing();
