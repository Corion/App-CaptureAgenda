package ZAI::Runner 0.01;
use 5.020;
use experimental 'signatures';

use File::Spec;
use File::Temp;
use Carp 'croak';
use MIME::Base64 qw(encode_base64);
use Moo 2;
use JSON::PP;

=head1 NAME

ZAI::Runner - convenience functions to run prompts

=head1 METHODS

=head2 C<< ZAI::Runner->new >>

  my $zai = ZAI::Runner->new(
      agent_name => 'frobnicator/1.0',
      model      => 'glm-5.3',
      api_key    => 'your-api-key-here',
  );

=item B<agent_name> - name of the HTTP user agent

=item B<api_base> - URL base to use

Default is C<https://api.z.ai/api/paas/v4>

=item B<api_key> - the API key to use

=item B<json> - JSON object to use for encoding/decoding

=item B<max_tokens> - maximum number of tokens to be generated as output

=item B<prompt> - the prompt to use

=item B<temperature> - temperature to use

Default is 0.1

=item B<ua> - L<HTTP::Tiny> user agent to use

=cut

has 'ua' => (
    is => 'lazy',
    default => \&_build_ua,
);

has 'agent_name' => (
    is => 'rw',
    default => "zai-runner/" . __PACKAGE__->VERSION,
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

sub _build_ua( $self ) {
    return HTTP::Tiny->new(
        timeout => 300,
        agent   => $self->agent_name,
    );
};

=head2 C<< ->build_prompt %args >>

Builds a prompt request as a Perl object

  my $payload = $runner->build_prompt(
      prompt => ...,
      files  => [ ... ],
      model  => 'glm-4.6v',
  );

=cut

sub build_prompt( $self, %args ) {
    $args{ prompt } //= $self->prompt;
    $args{ files }  //= [];
    $args{ temperature } //= $self->temperature;
    $args{ model } //= $self->model;

    if( my $p = delete $args{ additional_instructions }) {
        $args{ prompt } .= "\n\nAdditional user instructions:\n$p\n";
    };

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
        temperature => $temperature,
        max_tokens  => $self->max_tokens,
    };

    return $payload,
}

=head2 C<< ->build_prompt_request %args >>

Builds L<HTTP::Tiny> request parameters

  my( $url, $opts ) = $runner->build_prompt_request( %args );

=cut

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
    return ($data, undef)
}

=head2 C<< ->pdf_to_image_parts $filename >>

Splits up a C<.pdf> file into separate PNG images using the external
C<pdftoppm> program from the Poppler library.

  my @pages = $runner->pdf_to_image_parts( 'foo.pdf' );

The pages are returned as base64-encoded PNG images in hashes like

  { url => 'data:image/png;base64,...' }

=cut

# Convert a PDF into one image part per page using poppler's pdftoppm.
sub pdf_to_image_parts( $self, $pdf ) {
    my $pdftoppm = 'pdftoppm';

    my $tmp = File::Temp->newdir('ics-import-XXXXXX', TMPDIR => 1);
    my $prefix = File::Spec->catfile($tmp->dirname, 'page');
    my @cmd = ($pdftoppm, '-png', '-r', '150', '--', $pdf, $prefix);
    system(@cmd) == 0
        or die "$pdftoppm failed to convert '$pdf' (status $?)\n";

    my @pages = sort glob("$prefix*.png");
    croak "pdftoppm produced no pages for '$pdf'\n" unless @pages;

    return map { {
        type      => 'image_url',
        image_url => { url => 'data:image/png;base64,' . $self->encode_file_b64($_) },
    } } @pages;
}

=head2 C<< ->run_request >>

Simplistic all-in-one helper to run a request and return the resuits
or error.

    my ($res, $err) = $zai->run_request( ... );
    die $err if $err;

=cut

sub run_request( $self, %args ) {

    my ($url, $opts) = $self->build_prompt_request(%args);
    my $res = $self->ua->post( $url, $opts );

    unless ($res->{success}) {
        my $detail = eval {
            my $d = JSON::PP->new->decode($res->{content});
            $d->{error}{message} // $d->{message} // '';
        } // '';
        return (undef, sprintf "z.ai request failed: %s %s %s\n",
            $res->{status}, $res->{reason}, $detail);
    }

    return $self->decode_response( $res->{content});
}

sub encode_file_b64( $self, $file ) {
    open my $fh, '<:raw', $file or croak "Cannot read $file: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    return encode_base64($data, '');
}

1;
