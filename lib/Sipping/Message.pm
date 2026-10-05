package Sipping::Message;

use v5.40;
use Moo;
use Types::Standard qw(ArrayRef Str Tuple);

my $CRLF = "\r\n";

# RFC 3261 section 7.3.3 compact header names.
my %FULL_NAME_OF = (
    c => 'content-type',
    e => 'content-encoding',
    f => 'from',
    i => 'call-id',
    k => 'supported',
    l => 'content-length',
    m => 'contact',
    s => 'subject',
    t => 'to',
    v => 'via',
);

has start_line => (is => 'ro', isa => Str, required => 1);
has headers    => (is => 'ro', isa => ArrayRef [Tuple [Str, Str]], default => sub { [] });
has body       => (is => 'ro', isa => Str, default => '');

sub options_request ($class, %args) {
    my $target    = $args{target};
    my $local     = _host_port($args{local_host}, $args{local_port});
    my $transport = uc $target->transport;
    my $contact =
        $target->transport eq 'tcp' ? "<sip:sipping\@$local;transport=tcp>" : "<sip:sipping\@$local>";
    return $class->new(
        start_line => sprintf('OPTIONS %s SIP/2.0', $target->uri),
        headers    => [
            ['Via',            "SIP/2.0/$transport $local;branch=$args{branch};rport"],
            ['Max-Forwards',   '70'],
            ['From',           "<sip:sipping\@$local>;tag=$args{tag}"],
            ['To',             sprintf('<%s>', $target->uri)],
            ['Call-ID',        $args{call_id}],
            ['CSeq',           '1 OPTIONS'],
            ['Contact',        $contact],
            ['Accept',         'application/sdp'],
            ['User-Agent',     $args{user_agent}],
            ['Content-Length', '0'],
        ],
    );
}

sub parse ($class, $text) {
    my ($head, $body) = split /\r?\n\r?\n/, $text, 2;
    die "malformed SIP message: empty\n" unless defined $head && length $head;

    my ($start_line, @lines) = split /\r?\n/, $head =~ s/\r?\n[ \t]+/ /gr;
    die "malformed SIP message: bad start line '$start_line'\n"
        unless $start_line =~ m{\ASIP/2\.0 \d{3} } || $start_line =~ m{\A[A-Z]+ \S+ SIP/2\.0\z};

    my @headers = map { _parse_header($_) } @lines;
    return $class->new(start_line => $start_line, headers => \@headers, body => $body // '');
}

sub extract ($class, $buffer_ref) {
    $$buffer_ref =~ s/\A(?:\r\n)+//;
    my $header_end = index $$buffer_ref, "$CRLF$CRLF";
    return if $header_end < 0;

    my $head             = substr $$buffer_ref, 0, $header_end;
    my ($content_length) = $head =~ /^(?:content-length|l)[ \t]*:[ \t]*(\d+)/im;
    my $total            = $header_end + length("$CRLF$CRLF") + ($content_length // 0);
    return if length $$buffer_ref < $total;

    return substr $$buffer_ref, 0, $total, '';
}

sub header ($self, $name) {
    my $wanted = _full_name($name);
    my ($result) = map { $_->[1] } grep { _full_name($_->[0]) eq $wanted } $self->headers->@*;
    return $result;
}

sub is_response ($self) {
    return $self->start_line =~ m{\ASIP/2\.0 };
}

sub status_code ($self) {
    my ($result) = $self->start_line =~ m{\ASIP/2\.0 (\d{3})};
    return $result;
}

sub reason_phrase ($self) {
    my ($result) = $self->start_line =~ m{\ASIP/2\.0 \d{3} (.*)\z};
    return $result;
}

sub request_method ($self) {
    my ($result) = $self->start_line =~ m{\A([A-Z]+) \S+ SIP/2\.0\z};
    return $result;
}

sub as_string ($self) {
    my @header_lines = map { "$_->[0]: $_->[1]" } $self->headers->@*;
    return join($CRLF, $self->start_line, @header_lines, '', '') . $self->body;
}

sub _parse_header ($line) {
    my ($name, $value) = $line =~ /\A([^:\s]+)[ \t]*:[ \t]*(.*?)[ \t]*\z/
        or die "malformed SIP header: '$line'\n";
    return [$name, $value];
}

sub _full_name ($name) {
    my $lower = lc $name;
    return $FULL_NAME_OF{$lower} // $lower;
}

sub _host_port ($host, $port) {
    return $host =~ /:/ ? "[$host]:$port" : "$host:$port";
}

1;

__END__

=head1 NAME

Sipping::Message - an immutable SIP request or response

=head1 SYNOPSIS

    my $request = Sipping::Message->options_request(
        target     => $target,
        local_host => '192.0.2.10',
        local_port => 50600,
        branch     => 'z9hG4bK776asdhds',
        tag        => '1928301774',
        call_id    => 'a84b4c76e66710@sipping',
        user_agent => 'sipping/0.01',
    );
    $socket->send($request->as_string);

    my $response = Sipping::Message->parse($datagram);
    say $response->status_code if $response->is_response;

=head1 DESCRIPTION

Just enough of RFC 3261 to send C<OPTIONS> requests and read the responses:
header folding, case-insensitive and compact header names, and
C<Content-Length> framing for stream transports.

=head1 CONSTRUCTORS

=head2 new(start_line => $line, headers => \@pairs, body => $body)

Creates a message from its parts. C<headers> is an array of C<[name, value]>
pairs in wire order and defaults to none; C<body> defaults to empty.

=head2 options_request(%args)

Returns an C<OPTIONS> request for a L<Sipping::Target>. Takes C<target>,
C<local_host> and C<local_port> (the sending socket's address, used in C<Via>,
C<From> and C<Contact>), C<branch> (which must start with the RFC 3261 magic
cookie C<z9hG4bK>), C<tag>, C<call_id> and C<user_agent>.

=head2 parse($text)

Parses one complete message. Dies with a message beginning C<malformed SIP>
if the start line or a header cannot be parsed.

=head1 CLASS METHODS

=head2 extract(\$buffer)

For stream transports: removes the first complete message from C<$buffer> and
returns its text, using C<Content-Length> to find its end. Leading CRLF
keep-alives are discarded. Returns nothing if the buffer does not yet hold a
whole message.

=head1 METHODS

=head2 header($name)

Returns the value of the first header called C<$name>, matched
case-insensitively and with compact forms, or C<undef> if absent.

=head2 is_response

True if this is a response.

=head2 status_code

The response's three-digit status code, or C<undef> for a request.

=head2 reason_phrase

The response's reason phrase, or C<undef> for a request.

=head2 request_method

The request's method, or C<undef> for a response.

=head2 as_string

The message in wire format.

=cut
