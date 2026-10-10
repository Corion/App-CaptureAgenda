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

use Getopt::Long qw(:config bundling no_ignore_case);
use Pod::Usage;

use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();
use HTTP::Tiny;
use JSON::PP ();
use MIME::Base64 qw(encode_base64);
use YAML::Tiny ();
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
        'prompt|p=s',
        'model=s',
        'days|i=i',
        'all|a',
        'verbose|v',
    ) or pod2usage(-exitval => 2, -verbose => 1);

    if ($o{version}) { print "ics-import $VERSION\n"; return 0 }
    if ($o{help})    { pod2usage(-exitval => 0, -verbose => 1) }
    if ($o{man})     { pod2usage(-exitval => 0, -verbose => 2) }

    my $command = shift @ARGV;
    pod2usage(-exitval => 2, -verbose => 1, -message => 'No command given')
        unless defined $command;
    pod2usage(-exitval => 2, -verbose => 1,
              -message => "Unknown command '$command' (try --help)")
        unless $command =~ /^(?:init|import|photo)$/;

    %OPT = %o;
    $OPT{prompt} = $EXTRACTION_PROMPT . ($o{prompt} ? "\n\nAdditional user instructions:\n$o{prompt}\n" : '');

    my $code = __PACKAGE__->can("cmd_$command")->(\@ARGV);
    return $code;
}

# --- init ------------------------------------------------------------------

sub cmd_init {
    my ($args) = @_;
    pod2usage(-exitval => 2, -verbose => 1, -message => "init takes no arguments")
        if @$args;

    my ($path, $exists) = config_paths();
    if ($exists) {
        print "Config already exists: $path\n";
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

    my $n_total = 0;
    my $n_files = 0;
    for my $source (@$args) {
        my $ics = slurp_ics_source($source);
        my ($count) = import_ics_text($ics, $source);
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

    my $ics = zai_ics_from_files($args);
    if ($OPT{out}) {
        open my $fh, '>', $OPT{out} or die "Cannot write $OPT{out}: $!\n";
        binmode $fh;
        print {$fh} $ics;
        close $fh;
        print "Wrote extracted ICS to $OPT{out}\n";
    }

    if ($OPT{'no-import'}) {
        print $ics, "\n" unless $OPT{out};
        return 0;
    }
    import_ics_text($ics, ($OPT{out} ? $OPT{out} : join(' ', @$args)));
    return 0;
}

# ---------------------------------------------------------------------------
# Import engine (shared by 'import' and 'photo')
# ---------------------------------------------------------------------------

sub import_ics_text {
    my ($ics, $label) = @_;

    die "The ICS payload from '$label' is empty.\n"
        unless defined $ics && length $ics;

    my $caldav;
    my $cal;
    unless ($OPT{'dry-run'}) {
        $caldav = connect_caldav();
        $cal    = pick_calendar($caldav);
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
        print "      -> $href\n" if $OPT{verbose};
    }

    if ($OPT{'dry-run'}) {
        print "Dry run: nothing was uploaded.\n";
    }
    else {
        printf "Imported %d of %d event(s) into calendar '%s'.\n",
            $created, scalar(@events), $cal->{name};
        print "Note: re-importing the same UIDs updates the events in place.\n";
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

sub slurp_ics_source {
    my ($source) = @_;
    if ($source =~ m{^https?://}i or $source =~ m{^webcal://}i) {
        (my $url = $source) =~ s{^webcal://}{http://}i;
        print "Fetching $url ...\n" if $OPT{verbose};
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
    open my $fh, '<', $source or die "Cannot read $source: $!\n";
    binmode $fh;
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

# ---------------------------------------------------------------------------
# z.ai: turn images / PDFs into an ICS file
# ---------------------------------------------------------------------------

sub zai_ics_from_files {
    my ($files) = @_;

    my $cfg     = config();
    my $api_key = $cfg->{zai_api_key} // '';
    die <<"EOT" unless length $api_key;
No z.ai API key configured. Get one at https://z.ai and either
  * set  ZAI_API_KEY  in the environment, or
  * put  "zai_api_key"  into the config file (see: ics-import.pl init)
EOT

    my $base  = ($cfg->{zai_api_base} || $ZAI_API_BASE_DEFAULT);
    $base     =~ s{/+$}{};
    my $model = $OPT{model} || $cfg->{zai_model} || $ZAI_MODEL_DEFAULT;

    # Build multimodal content parts
    my @parts = ( { type => 'text', text => $OPT{prompt} } );
    for my $file (@$files) {
        die "No such file: $file\n" unless -f $file;
        my $ext = lc( ($file =~ m{\.([^.]+)$})[0] // '' );
        if ($ext eq 'pdf') {
            push @parts, pdf_to_image_parts($file);
        }
        else {
            my %mime = (
                jpg => 'image/jpeg', jpeg => 'image/jpeg',
                png => 'image/png',  gif  => 'image/gif',
                webp=> 'image/webp', bmp  => 'image/bmp',
            );
            my $m = $mime{$ext}
                or die "Unsupported file type '.$ext' for '$file' (use jpg/png/gif/webp/bmp or pdf)\n";
            push @parts, {
                type      => 'image_url',
                image_url => { url => 'data:' . $m . ';base64,' . encode_file_b64($file) },
            };
        }
    }

    my $payload = {
        model       => $model,
        messages    => [ { role => 'user', content => \@parts } ],
        temperature => 0.1,
        max_tokens  => $ZAI_MAX_TOKENS,
    };

    my $json = JSON::PP->new->canonical(1);
    print "Calling z.ai model '$model' with " . scalar(@$files) . " file(s) ...\n"
        if $OPT{verbose};

    my $ua = HTTP::Tiny->new(
        timeout    => 300,            # vision extraction can be slow
        agent      => "ics-import/$VERSION",
    );
    my $res = $ua->post(
        "$base/chat/completions",
        {
            headers => {
                'Authorization' => "Bearer $api_key",
                'Content-Type'  => 'application/json',
            },
            content => $json->encode($payload),
        },
    );

    unless ($res->{success}) {
        my $detail = eval {
            my $d = JSON::PP->new->decode($res->{content});
            $d->{error}{message} // $d->{message} // '';
        } // '';
        die sprintf "z.ai request failed: %s %s %s\n",
            $res->{status}, $res->{reason}, $detail;
    }

    my $data    = $json->decode($res->{content});
    my $choice  = $data->{choices}[0]{message}{content};
    if (ref $choice eq 'ARRAY') {   # some providers return message parts
        $choice = join '', map { $_->{text} // '' } @$choice;
    }
    die "z.ai returned an empty response.\n" unless defined $choice && length $choice;

    if ($data->{usage}) {
        printf "[usage: %s tokens]\n", $data->{usage}{total_tokens} if $OPT{verbose};
    }

    my $ics = extract_ics($choice);
    if (!defined $ics) {
        my $peek = substr($choice, 0, 500);
        $peek =~ s/\s+\z//;
        die "Could not find an ICS calendar in the z.ai response.\n---\n$peek\n---\n";
    }
    print "Extracted ICS with ", scalar(() = $ics =~ /BEGIN:VEVENT/gi), " event(s).\n";
    return $ics;
}

sub encode_file_b64 {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot read $file: $!\n";
    binmode $fh;
    local $/;
    my $data = <$fh>;
    close $fh;
    return encode_base64($data, '');
}

# Convert a PDF into one image part per page using poppler's pdftoppm.
sub pdf_to_image_parts {
    my ($pdf) = @_;
    my $pdftoppm = 'pdftoppm';

    my $tmp = File::Temp->newdir('ics-import-XXXXXX', TMPDIR => 1);
    my $prefix = File::Spec->catfile($tmp->dirname, 'page');
    my @cmd = ($pdftoppm, '-png', '-r', '150', '--', $pdf, $prefix);
    system(@cmd) == 0
        or die "$pdftoppm failed to convert '$pdf' (status $?)\n";

    my @pages = sort glob("$prefix*.png");
    die "pdftoppm produced no pages for '$pdf'\n" unless @pages;
    print "Converted PDF to ", scalar(@pages), " page image(s)\n" if $OPT{verbose};

    return map { {
        type      => 'image_url',
        image_url => { url => 'data:image/png;base64,' . encode_file_b64($_) },
    } } @pages;
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

sub connect_caldav {
    my $cfg = config();

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

sub pick_calendar {
    my ($caldav) = @_;
    my $cfg   = config();
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
