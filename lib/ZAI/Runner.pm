package ZAI::Runner 0.01;
use 5.020;
use experimental 'signatures';

use Carp 'croak';
use MIME::Base64 qw(encode_base64);
use Moo 2;
use JSON::PP;

has 'ua' => (
    is => 'lazy',
    default => \&_build_ua,
);

has 'json' => (
    is => 'lazy',
    default => sub { JSON::PP->new->canonical(1) },
);

has 'model' => (
    is => 'ro',
);

has 'api_base' => (
    is => 'ro',
    default => 'https://api.z.ai/api/paas/v4',
);

has 'api_key' => (
    is       => 'ro',
    required => 1, # my most common source of error is forgetting to supply it
);

has 'temperature' => (
    is => 'ro',
    default => 0.1,
);

has 'max_tokens' => (
    is => 'ro',
    default => 8192,
);

has 'prompt' => (
    is => 'rw',
);

sub build_prompt( $self, %args ) {
    $args{ prompt } //= $self->prompt;
    $args{ files }  //= [];
    $args{ temperature } //= 0.1;
    $args{ model } //= $self->model;

    my @parts = ( { type => 'text', text => $args{prompt} } );

    for my $file ($args{files}->@*) {
        croak "No such file: '$file'"
            unless -f $file;
        my $ext = lc( ($file =~ m{\.([^.]+)$})[0] // '' );
        if ($ext eq 'pdf') {
            push @parts, pdf_to_image_parts($file);
        }
        else {
            my %mime = (
                bmp  => 'image/bmp',
                gif  => 'image/gif',
                jpg  => 'image/jpeg',
                jpeg => 'image/jpeg',
                png  => 'image/png',
                webp => 'image/webp',
            );
            my $m = $mime{$ext}
                or die "Unsupported file type '.$ext' for '$file' (use jpg/png/gif/webp/bmp or pdf)\n";
            push @parts, {
                type      => 'image_url',
                image_url => { url => 'data:' . $m . ';base64,' . $self->encode_file_b64($file) },
            };
        }
    }

    my $payload = {
        model       => ($args{ model } // $self->model),
        messages    => [ { role => 'user', content => \@parts } ],
        temperature => 0.1,
        max_tokens  => $self->max_tokens,
    };

    return $payload,
}

sub build_prompt_request( $self, %args ) {
    my $api_key = delete $args{ api_key } // $self->api_key;
    my $payload = $self->build_prompt( %args );
    my $json = $self->json;
    my @request = (
        $self->api_base . "/chat/completions",
        {
            headers => {
                'Authorization' => "Bearer $api_key",
                'Content-Type'  => 'application/json',
            },
            content => $json->encode($payload),
        },
    );
}

sub decode_response( $self, $res_body ) {
    my $json   = $self->json;
    my $data   = $json->decode($res_body);
    return $data
}

# Convert a PDF into one image part per page using poppler's pdftoppm.
sub pdf_to_image_parts( $self, $pdf ) {
    my $pdftoppm = 'pdftoppm';

    my $tmp = File::Temp->newdir('ics-import-XXXXXX', TMPDIR => 1);
    my $prefix = File::Spec->catfile($tmp->dirname, 'page');
    my @cmd = ($pdftoppm, '-png', '-r', '150', '--', $pdf, $prefix);
    system(@cmd) == 0
        or die "$pdftoppm failed to convert '$pdf' (status $?)\n";

    my @pages = sort glob("$prefix*.png");
    die "pdftoppm produced no pages for '$pdf'\n" unless @pages;
    verbose( sprintf "Converted PDF to %d page image(s)", scalar(@pages) );

    return map { {
        type      => 'image_url',
        image_url => { url => 'data:image/png;base64,' . $self->encode_file_b64($_) },
    } } @pages;
}

sub encode_file_b64( $self, $file ) {
    open my $fh, '<:raw', $file or croak "Cannot read $file: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    return encode_base64($data, '');
}

1;
