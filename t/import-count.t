#!/usr/bin/perl
#
# t/import-count.t -- the /import counting helper
#
# import_events( $caldav, $cal, \@events ) must count created vs failed
# events. User selection is authoritative: every selected event is sent
# to the calendar (re-importing a UID updates it in place), regardless
# of what is already on the server.
#
use strict;
use warnings;

use File::Basename;
use lib dirname(__FILE__) . '/../lib';

use Test::More;
use Cwd 'abs_path';
use File::Temp ();
use Mojo::File 'path';

package FakeCalDAV {
    sub new { my ( $class, %args ) = @_; return bless { calls => [], %args }, $class }
    sub NewEvent {
        my ( $self, $cal_id, $ev ) = @_;
        push $self->{calls}->@*, $ev->{uid};
        die "simulated server failure for $ev->{uid}\n"
            if $self->{fail_uids}{ $ev->{uid} };
        return "https://caldav.example/$cal_id/$ev->{uid}.ics";
    }
}

package main;

my $dir = dirname(__FILE__);
my $tmp = File::Temp->newdir;

$ENV{ZAI_API_KEY}               = 'test-key';
$ENV{CAPTURE_AGENDA_UPLOAD_DIR} = path( $tmp->dirname )->to_string;

require( abs_path("$dir/../scripts/capture-agenda.pl") );

my @events = ( { uid => 'uid-a' }, { uid => 'uid-b' } );

subtest 'success and failure are counted separately' => sub {
    my $fake = FakeCalDAV->new( fail_uids => { 'uid-b' => 1 } );
    my ( $created, $failed ) = main::import_events( $fake, { id => 'cal-1' }, \@events );
    is( $created, 1, 'one event created' );
    is( $failed,  1, 'one event failed' );
};

subtest 'every selected event is attempted; re-import is not blocked' => sub {
    my $fake = FakeCalDAV->new;
    my ( $created, $failed ) = main::import_events( $fake, { id => 'cal-1' }, \@events );
    is( $created, 2, 'both created' );
    is_deeply( $fake->{calls}, [ 'uid-a', 'uid-b' ], 'NewEvent called for each selected event' );
};

subtest 'all successes' => sub {
    my $fake = FakeCalDAV->new;
    my ( $created, $failed ) = main::import_events( $fake, { id => 'cal-1' }, \@events );
    is( $created, 2, 'both created' );
    is( $failed,  0, 'none failed' );
};

done_testing();
