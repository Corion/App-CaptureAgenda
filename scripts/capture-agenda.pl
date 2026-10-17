#!/usr/bin/perl
use 5.020;
use experimental 'signatures';
use Mojolicious::Lite;
use Mojo::File 'path';
plugin 'RenderFile';
use ZAI::Runner;
use Digest::MD5 'md5_hex';
use File::Spec;
use File::Basename 'dirname';
use YAML::Tiny 'LoadFile';
use Encode 'decode';
use Text::JSCalendar;

our $VERSION = '0.01';

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

my $config = config();

$config->{upload_dir} //= File::Spec->catdir( dirname($0),  '../uploads' );

my $runner = ZAI::Runner->new(
    api_base    => $config->{zai_api_base},
    api_key     => $config->{zai_api_key},
    agent_name  => "ics-import/$VERSION",
    model       => $config->{zai_model},
    prompt      => $EXTRACTION_PROMPT,
    temperature => 0.1,
    max_tokens  => 8192,
);

get '/' => sub( $c ) {
    $c->redirect_to('index.html')
};

get '/index.html' => sub( $c ) {
    return $c->render('index')
};


my %inflight;
post '/extract' => sub ( $c ) {
    my @i = $c->every_param('images')->@*;
    my $prompt = $c->param('prompt');

    # save request id
    my $request_id;

    my @images;

    # read image file content
    my $idx = 0;
    for my $img (@i) {
        $request_id //= md5_hex($img->slurp());

        my $ics = File::Spec->catfile( $config->{upload_dir}, "$request_id.ics");
        if( -f $ics ) {
            $inflight{ $request_id }->{done} = 1;
            $inflight{ $request_id }->{images} = [glob "$config->{upload_dir}/$request_id.*.*"];
            $inflight{ $request_id }->{content} = path($ics)->slurp();
            my $jsc = Text::JSCalendar->new();
            $inflight{ $request_id }->{events} = [sort { $a->{start} cmp $b->{start} } $jsc->vcalendarToEvents( $inflight{ $request_id }->{content})];
            return $c->redirect_to($c->url_for("/results")->query( "request-id" => $request_id ));
        }

        my $ct = $img->headers->content_type;

        my %mime = (
            'image/bmp'       => 'bmp',
            'image/gif'       => 'gif',
            'image/jpeg'      => 'jpg',
            'image/png'       => 'png',
            'image/webp'      => 'webp',
            'application/pdf' => 'pdf',
        );

        if( my $ext = $mime{ $ct }) {
            my $fn = join ".", $request_id, $idx++, $ext;
            my $target = File::Spec->catfile( $config->{upload_dir}, $fn );
            $img->move_to( $target );
            push @images, $target;
        }
    }

    # feed to $runner
    my( $url, $opts) = $runner->build_prompt_request(
        files => \@images,
        additional_instructions => $prompt,
    );

    # Kick off request as future
    my $ua = Mojo::UserAgent->new(
        inactivity_timeout => 300, # zai/processing can be slow
    );
    my $r = {
        done   => undef,
        ua     => $ua,
        id     => $request_id,
        images => \@images,
    };

    $ua->post_p( $url => $opts->{headers} => $opts->{content})
    ->then(sub($tx) {
        $inflight{ $request_id }
            or warn "Inconsistent transaction ids ?! '$tx' is unknown";

        $inflight{ $request_id }->{done} = 1;
        my ($res, $err) = $runner->decode_response("".$tx->res->body);
        if( $err) {
            warn $err;
            # Should display an error to the user, but we bail
            return
        };
        $inflight{ $request_id }->{content} = decode('UTF-8', $res->{choices}->[0]->{message}->{content});
        $inflight{ $request_id }->{reqsoning_content} = decode('UTF-8', $res->{choices}->[0]->{message}->{reasoning_content});

        my $jsc = Text::JSCalendar->new();
        $inflight{ $request_id }->{events} = [sort { $a->{start} cmp $b->{start} } $jsc->vcalendarToEvents( $inflight{ $request_id }->{content})];

        path($config->{upload_dir})->child("$request_id.ics")->spew( $inflight{ $request_id }->{content}, 'UTF-8');
        path($config->{upload_dir})->child("$request_id.reasoning.txt")->spew( $inflight{ $request_id }->{reqsoning_content}, 'UTF-8');

    })
    ->catch(sub {
        warn "@_";
    });
    $inflight{ $request_id } = $r;
    warn "Launched request for $request_id";

    # redirect to request completion poll page
    return $c->redirect_to($c->url_for("/results")->query( "request-id" => $request_id ));
};

get '/calendar' => sub( $c ) {
    my $r = $c->param('request-id');
    my $type = $c->param('type');

    my $req = $inflight{ $r };

    $c->stash( request => $req );
    $c->stash( 'request_id' => $r );
    $c->stash( 'type' => $type );

    return $c->render( 'calendar-frag' );
};

get '/results' => sub ( $c ) {
    my $r = $c->param('request-id');
    my $type = $c->param('type');

    my $req = $inflight{ $r };

    $c->stash( request => $req );
    $c->stash( 'request_id' => $r );
    $c->stash( 'thumbnail' => $req->{images}->[0] );
    $c->stash( 'result_type' => $type );

    return $c->render( 'results' );
};

get '/thumbnail/<*image>.0.<:ext>' => [ ext => ['bmp','gif','jpg','jpeg','pdf','png','webp'] ] => sub( $c ) {
    my $image_id = $c->param('image');
    $c->render_file(
        filepath => $inflight{ $image_id }->{images}->[0],
        content_disposition => 'inline',
    );
};

post '/import' => sub( $c ) {
    # import into $calendar
};

app->start;

__END__

__DATA__
@@ htmx-header.html.ep
<meta htmx.config.allowScriptTags="true">
<meta name="viewport" content="width=device-width, initial-scale=1.0, interactive-widget=resizes-content" />
<link rel="manifest" href="<%= url_for('/manifest.json') %>">
<meta name="theme-color" content="#fbbf24">
<link rel="stylesheet" href="<%= url_for( "/vendor/bootstrap.5.3.3.min.css" ) %>" integrity="sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH" crossorigin="anonymous">
<script src="<%= url_for( "/vendor/htmax.4.0.0.min.js") %>"></script>
<script src="<%= url_for( "/vendor/bootstrap.5.3.3.min.js") %>"></script>
<script>
//htmx.logAll();

// Hack to show us what element caused the syntax error
// We still don't know what attribute, but that's close enough
htmx.on("htmx:syntax:error", (elt) => { console.log("htmx.syntax.error",elt)});
</script>

@@ index.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">

%=include 'htmx-header'

<title>Extract agenda from image</title>
</head>
<body
    id="body"
    hx-ext="morphdom-swap"
    hx-swap="morphdom"
>
<div class="container-fluid" id="container">
    <main class="col">
        <form action="<%= url_for( "/extract" ) %>" method="POST"
            enctype='multipart/form-data'
            hx-trigger="change"
            id="form-upload-image"
        >
            <label for="upload-images">&#128247;</label>
            <input id="upload-images" type="file" accept="image/*"
                   name="images" id="capture-image-image"
                   style="display: none"
                   capture="environment"
            /><br />
            <button type="submit" class="nojs">Analyze</button><br />
            <textarea name="prompt" placeholder="Additional instructions here"></textarea>
        </form>
    </main>
    </div>
</body>
</html>

@@ calendar-frag.html.ep
% if( $type eq 'raw' ) {
<pre><%= $request->{content} %></pre>
% } elsif( $type eq 'list' ) {
    <div>Select all</div>
<form method="POST" action="<%= url_for( "/import" ) %>">
<input type="hidden" name="request-id" value="<%= $request_id %>" />
<table>
%     my $idx = 0;
%     for my $ev ($request->{events}->@*) {
<tr>
    <td><input type="checkbox" id="import-<%= $idx %>" name="import" value="<%= $ev->{uid} %>"</td>
    <td><label for="import-<%= $idx++ %>"><%= $ev->{start} %></label></td>
    <td><%= $ev->{title} %></td>
    <td><%= $ev->{description} %></td>
</tr>
%     }
</table>
</form>
% }

@@ results.html.ep
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">

%=include 'htmx-header'

<title>Agenda from image</title>
</head>
<body
    id="body"
    hx-ext="morphdom-swap"
    hx-swap="morphdom"
>
<div class="container-fluid" id="container">
    <main class="col">
% my $status = $request->{done} ? "done" : "in progress";
% $result_type //= 'list';
<div id="request-id"><%= $request_id %> - <%= $status %></div>
% if( $request->{done} ) {
    <div id="poll-results">
        <ul>
            <li><a hx-get="<%= url_for("/calendar")->query("request-id"=>$request_id, type => 'list') %>" hx-target="next div" href="<%= url_with->query( type => "list" )%>">list</a></li>
            <li><a hx-get="<%= url_for("/calendar")->query("request-id"=>$request_id, type => 'raw' ) %>" hx-target="next div" href="<%= url_with->query( type => "raw" )%>">raw</a></li>
            <li><a href="<%= url_for( "/ics/$request_id.ics" )%>">download .ics</a></li>
            <li><form method="POST" action="<%= url_for("/import")->query("request-id"=>$request_id, uid=>'all')%>"><button type="submit" href="<%= url_for( "/calendar" )%>">import all</button></form></li>
        </ul>
        <div id="calendar-content">
%=include('calendar-frag', request_id => $request_id, type => $result_type, request => $request );
        </div>
    </div>
% } else {
    <div id="poll-results" hx-get="<%= url_for( "/results" )->query("request-id" => $request_id ) %>" hx-trigger="every 5s" hx-target="#body"></div>
% }
% use File::Basename;
        <img src="<%= url_for( "/thumbnail/" . basename( $thumbnail )) %>" />
    </main>
    </div>
</body>
</html>
