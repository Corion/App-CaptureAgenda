#!/usr/bin/env perl
#
# ics-import.pl -- multi-event ICS importer
#
# Read ICS calendar files (or create them from photos/PDFs via the z.ai API)
# and push every event they contain into a CalDAV calendar using
# Net::CalDAVTalk.  Designed to run anywhere Perl runs, including Termux on
# Android.
#
# See the POD at the bottom of this file (perldoc ics-import.pl) for the full
# manual, including Termux installation instructions.

use 5.020;
use experimental 'signatures';

use lib 'lib';

use Getopt::Long qw(:config bundling no_ignore_case);
use Pod::Usage;

use POSIX 'strftime';
use File::Copy 'cp';
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();
use HTTP::Tiny;
use JSON::PP ();
use YAML::Tiny ();
use ZAI::Runner;
use Net::CalDAVTalk;

our $VERSION = '1.00';

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

my $ZAI_API_BASE_DEFAULT = 'https://api.z.ai/api/paas/v4';
my $ZAI_MODEL_DEFAULT    = 'glm-4.5v';       # vision model, sees images/PDF pages
my $ZAI_MAX_TOKENS       = 8192;

my $EXTRACTION_PROMPT = <<'EOP';
You are an assistant that turns photographs, scans and documents into
calendar data. Examine the attached image(s) carefully and find EVERY
calendar event, appointment, reservation, deadline or schedule entry,
including multi-day and recurring ones.

Return ONLY a valid iCalendar (ICS) file body:
BEGIN:VCALENDAR ... END:VCALENDAR with VERSION:2.0 and a PRODID line,
containing exactly one VEVENT per event you found.

Every VEVENT MUST have: UID (invent a stable unique one), DTSTAMP, SUMMARY,
DTSTART and DTEND (or DURATION). Use TZID-prefixed local times (e.g.
DTSTART;TZID=Europe/Berlin:20261007T190000) when the source shows local
times, and VALUE=DATE for all-day events. Include LOCATION and DESCRIPTION
whenever the information is available; put anything uncertain in the
DESCRIPTION.

Do NOT add any commentary or explanation, do NOT use markdown code fences,
output only the raw ICS text.
EOP

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

my %OPT;    # global option hash

sub main {
    my @argv = @_;

    local @ARGV = @argv;
    GetOptions(
        \my %o,
        'help|h',
        'version|V',
        'calendar|c=s',
        'password=s',
        'dry-run|n',
        'skip-existing',
        'no-import',
        'out|o=s',
        'archive=s',
        'prompt|p=s',
        'model=s',
        'verbose|v',
    ) or pod2usage(-exitval => 2, -verbose => 1);

    if ($o{version}) { say "ics-import $VERSION"; return 0 }
    if ($o{help})    { pod2usage(-exitval => 0, -verbose => 1) }
    if ($o{man})     { pod2usage(-exitval => 0, -verbose => 2) }

    my $command = shift @ARGV;
    pod2usage(-exitval => 2, -verbose => 1, -message => 'No command given')
        unless defined $command;
    pod2usage(-exitval => 2, -verbose => 1,
              -message => "Unknown command '$command' (try --help)")
        unless $command =~ /^(?:init|import|photo)$/;

    %OPT = %o;
    $OPT{ archive } //= File::Spec->catdir( $ENV{ XDG_DATA_HOME }, 'ics-import' );
    if( ! -d $OPT{ archive }) {
        mkdir $OPT{ archive }
            or warn "Couldn't create archive dir '$OPT{archive}': $!";
    }
    $OPT{prompt} = $EXTRACTION_PROMPT . ($o{prompt} ? "\n\nAdditional user instructions:\n$o{prompt}\n" : '');

    my $code = __PACKAGE__->can("cmd_$command")->(\@ARGV);
    return $code;
}

sub verbose(@msg) {
    if( $OPT{verbose}) {
        say $_ for @msg;
    }
}

# --- init ------------------------------------------------------------------

sub cmd_init {
    my ($args) = @_;
    pod2usage(-exitval => 2, -verbose => 1, -message => "init takes no arguments")
        if @$args;

    my ($path, $exists) = config_paths();
    if ($exists) {
        say "Config already exists: $path";
        return 0;
    }
    my $fallback = 0;
    my $dir = dirname($path);
    if (!eval { make_path($dir); 1 }) {
        # Fall back to ~/.ics-import.yaml when the XDG dir is not writable
        # (should not happen under Termux, but be forgiving).
        $path    = File::Spec->catfile($ENV{HOME} // '.', '.ics-import.yaml');
        $fallback = 1;
    }
    die "Refusing to overwrite existing $path\n" if -e $path;

    my $template = <<'EOT';
---
# ics-import.pl configuration

# CalDAV server, account and default target calendar
url:      https://caldav.example.com/
user:     you@example.com
password: app-specific-password
calendar: Personal

# optional: z.ai API for the 'photo' command
#zai_api_key: your-z.ai-api-key
#zai_model:   glm-4.5v
#zai_api_base: https://api.z.ai/api/paas/v4

EOT
    open my $fh, '>', $path or die "Cannot write $path: $!\n";
    print {$fh} $template;
    close $fh;
    chmod 0600, $path;

    print <<"EOT";
Created starter config: $path
EOT
    return 0;
}

# --- import ----------------------------------------------------------------

sub cmd_import {
    my ($args) = @_;
    pod2usage(-exitval => 2, -verbose => 1,
              -message => 'usage: ics-import.pl import [--calendar NAME] FILE.ics [FILE.ics | URL ...]')
        unless @$args;

    my $cfg = config();

    my $n_total = 0;
    my $n_files = 0;
    for my $source (@$args) {
        my $ics = slurp_ics_source($source);
        my ($count) = import_ics_text($cfg,$ics, $source);
        $n_total  += $count;
        $n_files  += 1;
    }
    printf "%d event(s) in %d source(s) processed.\n", $n_total, $n_files;
    return 0;
}

# --- photo / pdf -> ICS via z.ai -------------------------------------------

sub cmd_photo {
    my ($args) = @_;
    pod2usage(-exitval => 2, -verbose => 1,
              -message => 'usage: ics-import.pl photo [--prompt TEXT] [--out FILE.ics] [--dry-run|--no-import] IMAGE|PDF [IMAGE|PDF ...]')
        unless @$args;

    my $cfg = config();
    my $ics = zai_ics_from_files($cfg, $args);
    if ($OPT{out}) {
        open my $fh, '>:raw', $OPT{out} or die "Cannot write $OPT{out}: $!\n";
        print {$fh} $ics;
        close $fh;
        say "Wrote extracted ICS to $OPT{out}";
    }

    if ($OPT{'no-import'}) {
        say $ics unless $OPT{out};
        return 0;
    }
    import_ics_text($cfg, $ics, ($OPT{out} ? $OPT{out} : join(' ', @$args)));
    return 0;
}

# ---------------------------------------------------------------------------
# Import engine (shared by 'import' and 'photo')
# ---------------------------------------------------------------------------

sub import_ics_text {
    my ($config, $ics, $label) = @_;

    die "The ICS payload from '$label' is empty.\n"
        unless defined $ics && length $ics;

    my $caldav;
    my $cal;
    unless ($OPT{'dry-run'}) {
        $caldav = connect_caldav($config);
        $cal    = pick_calendar($config, $caldav);
    }

    my @events = eval { $caldav
                        ? $caldav->vcalendarToEvents($ics)
                        : parse_events_offline($ics) };
    die "Could not parse ICS from '$label': $@\n" if $@;
    unless (@events) {
        warn "No VEVENT components found in '$label' -- nothing to do.\n";
        return (0, 0);
    }
    @events = sort { ($a->{start} // '') cmp ($b->{start} // '') } @events;

    my %existing;
    if ($OPT{'skip-existing'} && $caldav) {
        my $links = $caldav->GetEventLinks($cal->{id});
        %existing = map { $_ => 1 } map { basename($_) } keys %$links;
    }

    printf "Source: %s (%d event%s)%s\n",
        $label, scalar(@events), (@events == 1 ? '' : 's'),
        ($OPT{'dry-run'} ? '  [dry run]' : '');

    my $created = 0;
    my $i = 0;
    for my $ev (@events) {
        $i++;
        my $uid  = $ev->{uid} // '(no uid)';
        my $line = format_event_line($ev);

        # UID filename component (mirrors Net::CalDAVTalk::NewEvent)
        (my $uidfile = $uid) =~ tr/a-zA-Z0-9\@._-//cd;

        if ($OPT{'dry-run'}) {
            print "  [$i] would create  $line\n";
            next;
        }
        if ($existing{"$uidfile.ics"}) {
            print "  [$i] skip existing $line\n";
            next;
        }
        my $href = eval { $caldav->NewEvent($cal->{id}, $ev) };
        if (my $err = $@) {
            $err =~ s/ at \S+ line \d+.*//s;
            warn "  [$i] FAILED: $err";
            next;
        }
        $created++;
        print "  [$i] created      $line\n";
        verbose( "      -> $href");
    }

    if ($OPT{'dry-run'}) {
        say "Dry run: nothing was uploaded.";
    }
    else {
        say sprintf "Imported %d of %d event(s) into calendar '%s'.",
            $created, scalar(@events), $cal->{name};
        say "Note: re-importing the same UIDs updates the events in place.";
    }
    return (scalar @events, $created);
}

# Minimal offline parser used only for --dry-run, where we do not want to
# contact any server.  Produces just enough JSCalendar-ish fields for
# display; the real parse happens server-side via vcalendarToEvents above.
sub parse_events_offline {
    my ($ics) = @_;
    my @events;
    my %cur;
    my $in_event = 0;

    my $add = sub {
        return unless $in_event;
        $cur{title}           //= $cur{summary};
        $cur{showWithoutTime} = 1 if $cur{allday};
        push @events, {%cur};
        %cur      = ();
        $in_event = 0;
    };

    for my $line (split /\r?\n/, $ics) {
        if    ($line =~ /^BEGIN:VEVENT/i) { %cur = (); $in_event = 1; next }
        elsif ($line =~ /^END:VEVENT/i)   { $add->();             next }
        next unless $in_event;
        next unless $line =~ /^([A-Za-z0-9-]+)((?:;[^:]*)*):(.*?)\s*$/;
        my ($prop, $params, $val) = (uc $1, $2 // '', $3);
        my ($tzid) = $params =~ /(?:^|;)TZID=([^;:]+)/i;
        $cur{uid}     = $val  if $prop eq 'UID';
        $cur{summary} = unescape_ics($val) if $prop eq 'SUMMARY';
        $cur{location}= unescape_ics($val) if $prop eq 'LOCATION';
        if ($prop eq 'DTSTART') {
            $cur{start}    = $val;
            $cur{timeZone} = $tzid if defined $tzid;
            $cur{allday}   = 1 if $val =~ /^\d{8}$/ or $params =~ /VALUE=DATE/i;
        }
        if ($prop eq 'DTEND')     { $cur{end}      = $val }
        if ($prop eq 'DURATION')  { $cur{duration} = $val }
    }
    $add->();

    # synthesize uids for display when missing
    my $i = 0;
    for my $ev (@events) {
        $ev->{uid} //= sprintf 'no-uid-%d', ++$i;
    }
    return @events;
}

sub unescape_ics {
    my ($v) = @_;
    $v =~ s/\\n/\n/gi;
    $v =~ s/\\([,;\\])/$1/g;
    return $v;
}

sub format_event_line {
    my ($ev) = @_;
    my $start = $ev->{start} // '????-??-??';
    my $end   = $ev->{end};
    my $title = $ev->{title} // $ev->{summary} // '(no title)';
    my $extra = '';
    $extra .= ' [all day]'    if $ev->{showWithoutTime};
    $extra .= ' '.$ev->{timeZone} if $ev->{timeZone};
    $extra .= ' @ '.($ev->{location}//'') if defined $ev->{location} && length $ev->{location};
    return sprintf '%s%s  %s%s', $start,
        ($end ? " .. $end" : ''), $title, $extra;
}

sub slurp_ics_source( $source ) {
    if ($source =~ m{^(https?|webcal)://}i) {
        (my $url = $source) =~ s{^webcal://}{http://}i;
        verbose( "Fetching $url ..." );
        my $res = HTTP::Tiny->new(timeout => 60)->get($url);
        die "Failed to fetch $url: $res->{status} $res->{reason}\n"
            unless $res->{success};
        return $res->{content};
    }
    $source = '-' if $source eq 'stdin';
    if ($source eq '-') {
        local $/;
        binmode STDIN;
        return <STDIN>;
    }
    die "No such file: $source\n" unless -f $source;
    open my $fh, '<:raw', $source
        or die "Cannot read $source: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub spew( $file, $content ) {
    if( open my $fh, '>:raw', $file ) {
        print $fh $content;
    } else {
        warn "Couldn't create file '$file': $!";
    }
}

# ---------------------------------------------------------------------------
# z.ai: turn images / PDFs into an ICS file
# ---------------------------------------------------------------------------

sub zai_ics_from_files {
    my ($cfg,$files) = @_;

    my $api_key = $cfg->{zai_api_key} // '';
    die <<"EOT" unless length $api_key;
No z.ai API key configured. Get one at https://z.ai and either
  * set  ZAI_API_KEY  in the environment, or
  * put  "zai_api_key"  into the config file (see: ics-import.pl init)
EOT

    my $base  = ($cfg->{zai_api_base} || $ZAI_API_BASE_DEFAULT);
    $base     =~ s{/+$}{};
    my $model = $OPT{model} || $cfg->{zai_model} || $ZAI_MODEL_DEFAULT;

    my $zai = ZAI::Runner->new(
        api_base    => $base,
        api_key     => $api_key,
        model       => $model,
        prompt      => $EXTRACTION_PROMPT,
        temperature => 0.1,
        max_tokens  => $ZAI_MAX_TOKENS
    );

    my $ua = HTTP::Tiny->new(
        timeout    => 300,            # vision extraction can be slow
        agent      => "ics-import/$VERSION",
    );
    my ($url, $opts) = $zai->build_prompt_request(
        files => $files,
    );
    my $res = $ua->post( $url, $opts );

    unless ($res->{success}) {
        my $detail = eval {
            my $d = JSON::PP->new->decode($res->{content});
            $d->{error}{message} // $d->{message} // '';
        } // '';
        die sprintf "z.ai request failed: %s %s %s\n",
            $res->{status}, $res->{reason}, $detail;
    }

    my $json   = JSON::PP->new->canonical(1);
    my $data   = $json->decode($res->{content});
    my $choice = $data->{choices}[0]{message}{content};
    if (ref $choice eq 'ARRAY') {   # some providers return message parts
        $choice = join '', map { $_->{text} // '' } @$choice;
    }
    die "z.ai returned an empty response.\n" unless defined $choice && length $choice;

    if ($data->{usage}) {
        verbose( sprintf "[usage: %s tokens]\n", $data->{usage}{total_tokens} );
    }

    my $ics = extract_ics($choice);
    if (!defined $ics) {
        my $peek = substr($choice, 0, 500);
        $peek =~ s/\s+\z//;
        die "Could not find an ICS calendar in the z.ai response.\n---\n$peek\n---\n";
    }
    say "Extracted ICS with ", scalar(() = $ics =~ /BEGIN:VEVENT/gi), " event(s).";

    if( $OPT{archive}) {
        my $prefix = strftime '%Y%m%d-%H%M%S', gmtime;
        for my $file ($files->@*) {
            cp $file => File::Spec->catfile( $OPT{archive}, "$prefix-" . basename( $file ));
        }
        my $result_name = File::Spec->catfile($OPT{archive}, "$prefix.ics");
        spew( $result_name, $ics );
    }

    return $ics;
}

# Pull the raw VCALENDAR block out of a model reply (which may be wrapped in
# markdown fences or chatter).
sub extract_ics {
    my ($text) = @_;
    $text =~ s/\r//g;
    my @blocks = $text =~ /(BEGIN:VCALENDAR.*?END:VCALENDAR)/gis;
    for my $block (sort { length $b <=> length $a } @blocks) {
        next unless $block =~ /BEGIN:VEVENT/i;
        my $out = $block;
        $out =~ s/^\s+|\s+$//g;
        $out =~ s/\n/\r\n/g;          # RFC 5545 wants CRLF
        $out .= "\r\n";
        return $out;
    }
    return undef;
}

# ---------------------------------------------------------------------------
# CalDAV connection & calendar selection
# ---------------------------------------------------------------------------

sub connect_caldav($cfg) {
    my $url  = $cfg->{url}  or die "No CalDAV URL configured (CALDAV_URL or 'url' in the YAML config -- see: ics-import.pl init)\n";
    my $user = $cfg->{user} or die "No CalDAV user configured (CALDAV_USER or 'user' in the YAML config)\n";
    my $pass = $OPT{password} // $cfg->{password};
    die "No CalDAV password given. Use --password SECRET or set 'password' in the YAML config (see: ics-import.pl init).\n"
        unless defined $pass && length $pass;

    my %args = (
        url      => $url,
        user     => $user,
        password => $pass,
    );

    my $caldav = Net::CalDAVTalk->new(%args);
    $caldav->logger(sub {
        my ($level, @rest) = @_;
        return unless $OPT{verbose};
        warn "CALDAV $level: $_\n" for @rest;
    });

    return $caldav;
}

sub pick_calendar($cfg, $caldav) {
    my $want  = $OPT{calendar} // $cfg->{calendar};

    my $cals = $caldav->GetCalendars();
    die "The server returned no calendars.\n" unless $cals and @$cals;

    return $cals->[0] unless defined $want && length $want;

    # 1. exact id  2. exact name (case-insensitive)  3. unique substring
    for my $cal (@$cals) { return $cal if $cal->{id} eq $want }
    for my $cal (@$cals) {
        return $cal if lc($cal->{name} // '') eq lc $want;
    }
    my @match = grep { (($_->{name} // '') =~ /\Q$want\E/i) or ($_->{id} =~ /\Q$want\E/i) } @$cals;
    if (@match == 1) { return $match[0] }
    if (!@match) {
        die "No calendar matches '$want'. Available calendars:\n"
            . join('', map { "  - $_->{name} ($_->{id})\n" } @$cals);
    }
    die "Ambiguous calendar '$want', matches:\n"
        . join('', map { "  - $_->{name} ($_->{id})\n" } @match);
}

# ---------------------------------------------------------------------------
# Config: YAML file + command line + environment overrides
# ---------------------------------------------------------------------------

sub config_paths {
    my @candidates;
    my $xdg = $ENV{XDG_CONFIG_HOME} || (($ENV{HOME} // '') . '/.config');
    if (length $xdg) {
        push @candidates,
            map { File::Spec->catfile($xdg, 'ics-import', $_) }
            qw(config.yaml config.yml);
    }
    if (defined $ENV{HOME}) {
        push @candidates,
            map { File::Spec->catfile($ENV{HOME}, $_) }
            qw(.ics-import.yaml .ics-import.yml);
    }
    for my $p (@candidates) {
        return ($p, 1) if -e $p;
    }
    return ($candidates[0] // 'config.yaml', 0);
}

{
    my %CONFIG_CACHE;
    sub config {
        return \%CONFIG_CACHE if %CONFIG_CACHE;

        my %cfg;
        my ($path, $exists) = config_paths();
        if ($exists) {
            my $yaml = eval { YAML::Tiny->read($path) };
            my $data = $yaml ? $yaml->[0] : undef;
            unless (ref $data eq 'HASH') {
                warn "Warning: config file $path is not valid YAML -- ignored\n";
                $data = {};
            }
            %cfg = %$data;
        }

        # environment overrides
        my %env = (
            zai_api_key  => $ENV{ZAI_API_KEY},
            zai_model    => $ENV{ZAI_MODEL},
            zai_api_base => $ENV{ZAI_API_BASE},
        );
        for my $k (keys %env) {
            $cfg{$k} = $env{$k} if defined $env{$k};
        }

        %CONFIG_CACHE = %cfg;
        return \%CONFIG_CACHE;
    }
}

# ---------------------------------------------------------------------------
exit(main(@ARGV));

__END__

=head1 NAME

ics-import.pl - multi-event ICS importer for CalDAV calendars

=head1 SYNOPSIS

  ics-import.pl init
  ics-import.pl import [options] FILE.ics [FILE2.ics ... | URL]
  ics-import.pl photo   [options] IMAGE_or_PDF [IMAGE2 ...]

  Options:
    -c, --calendar NAME   target calendar (name or id; default: config)
        --password SECRET  CalDAV password (overrides the YAML config file)
    -n, --dry-run         parse and show events, do not upload anything
        --skip-existing   do not touch events whose UID already exists
    -v, --verbose         show details, incl. CalDAV wire log

  'photo' only:
    -p, --prompt TEXT     extra instructions for the extraction model
    -o, --out FILE.ics    save the extracted ICS to a file
        --no-import       do not upload; print (or save) the ICS only
        --model NAME      z.ai model (default: glm-4.5v)

=head1 DESCRIPTION

Reads iCalendar (.ics) files -- or creates them from photos and PDFs with
the z.ai vision API -- and creates every event they contain in a CalDAV
calendar.

=head1 CONFIGURATION

F<$XDG_CONFIG_HOME/ics-import/config.yaml> (or F<~/.ics-import.yaml>):

  ---
  url:      https://caldav.example.com/
  user:     you@example.com
  password: calendar-password
  calendar: Personal

  # optional keys for the 'photo' command:
  #zai_api_key: sk-...
  #zai_model:   glm-4.5v
  #zai_api_base: https://api.z.ai/api/paas/v4

The password may also be given per invocation with C<--password>, which
overrides the file. Environment overrides:
C<ZAI_API_KEY>, C<ZAI_MODEL>,
C<ZAI_API_BASE> (default https://api.z.ai/api/paas/v4).

=head1 EXAMPLES

  # first run: create + edit the YAML config, then check connectivity
  ics-import.pl init
  ${EDITOR:-vi} ~/.config/ics-import/config.yaml

  # ... or keep the password out of the file and pass it per run
  ics-import.pl --password xxxx-xxxx-xxxx calendars

  # import a multi-event file into a specific calendar
  ics-import.pl --calendar Personal import ~/storage/downloads/termine.ics

  # try first, then do it
  ics-import.pl import -n test.ics
  ics-import.pl import    test.ics

  # photograph a timetable, let z.ai build the ICS, import it
  ics-import.pl photo poster.jpg --prompt 'Only the concerts, ignore movies'
  ics-import.pl photo menu.pdf -o events.ics --no-import

=head1 TERMUX INSTALL

  pkg update
  pkg install perl make clang
  curl -L https://cpanmin.us -o ~/cpanm
  perl ~/cpanm --notests Net::CalDAVTalk YAML::Tiny
  # PDF support (optional):
  pkg install poppler
  # access files from Android shared storage:
  termux-setup-storage

  cd ~
  curl -O https://example.com/ics-import.pl   # or copy it here
  chmod +x ics-import.pl
  ./ics-import.pl init

=head1 EXIT STATUS

0 on success, non-zero with a diagnostic on STDERR otherwise.

=cut
