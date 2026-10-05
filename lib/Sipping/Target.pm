package Sipping::Target;

use v5.40;
use Moo;
use Type::Tiny;
use Types::Common::Numeric qw(IntRange PositiveNum);
use Types::Standard        qw(Enum Str);

my $Host = Type::Tiny->new(
    name       => 'Host',
    parent     => Str,
    constraint => sub { m{\A(?:[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?|[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*)\z} },
);

my %RULE_FOR = (
    host      => [$Host,                'must be a hostname or IP address'],
    port      => [IntRange [1, 65_535], 'must be an integer from 1 to 65535'],
    transport => [Enum [qw(udp tcp)],   'must be "udp" or "tcp"'],
    interval  => [PositiveNum,          'must be a positive number of seconds'],
);

has host      => (is => 'ro',   isa      => $RULE_FOR{host}[0],      required => 1);
has port      => (is => 'ro',   isa      => $RULE_FOR{port}[0],      default  => 5060);
has transport => (is => 'ro',   isa      => $RULE_FOR{transport}[0], default  => 'udp');
has interval  => (is => 'ro',   isa      => $RULE_FOR{interval}[0],  default  => 30);
has id        => (is => 'lazy', init_arg => undef);

sub _build_id ($self) {
    return join ':', $self->transport, _bracketed($self->host), $self->port;
}

sub from_spec ($class, $spec, %defaults) {
    my ($transport, $host, $port) = $spec =~ m{\A(?:(udp|tcp):)?(\[[^\]]+\]|[^:\[\]]+)(?::(\d+))?\z}
        or die "invalid target '$spec': expected [udp:|tcp:]host[:port]\n";
    return $class->new(
        %defaults,
        host => $host =~ s/\A\[(.*)\]\z/$1/r,
        (defined $transport ? (transport => $transport) : ()),
        (defined $port      ? (port      => $port)      : ()),
    );
}

sub validation_errors ($class, $fields) {
    my %unknown = map { $_ => 'is not a recognised field' } grep { !$RULE_FOR{$_} } keys $fields->%*;
    my %invalid = map { $_ => $RULE_FOR{$_}[1] }
        grep { exists $fields->{$_} && !$RULE_FOR{$_}[0]->check($fields->{$_}) } keys %RULE_FOR;
    my %missing = exists $fields->{host} ? () : (host => 'is required');
    return {%unknown, %invalid, %missing};
}

sub uri ($self) {
    my $base = sprintf 'sip:%s:%d', _bracketed($self->host), $self->port;
    return $self->transport eq 'tcp' ? "$base;transport=tcp" : $base;
}

sub to_hash ($self) {
    return {
        id        => $self->id,
        host      => $self->host,
        port      => 0 + $self->port,
        transport => $self->transport,
        interval  => 0 + $self->interval,
        uri       => $self->uri,
    };
}

sub _bracketed ($host) {
    return $host =~ /:/ ? "[$host]" : $host;
}

1;

__END__

=head1 NAME

Sipping::Target - a SIP endpoint to probe

=head1 SYNOPSIS

    my $target = Sipping::Target->new(host => 'pbx.example.com', transport => 'tcp');
    my $same   = Sipping::Target->from_spec('tcp:pbx.example.com:5060');
    say $target->id;     # tcp:pbx.example.com:5060
    say $target->uri;    # sip:pbx.example.com:5060;transport=tcp

=head1 DESCRIPTION

An immutable description of one endpoint: where it is, how to reach it and how
often to probe it. Its C<id> is derived from transport, host and port, so two
targets for the same endpoint have the same identity.

=head1 ATTRIBUTES

=head2 host

Hostname or IP address. Required.

=head2 port

Port number, 1-65535. Defaults to 5060.

=head2 transport

C<udp> or C<tcp>. Defaults to C<udp>.

=head2 interval

Seconds between probes. Defaults to 30.

=head2 id

C<transport:host:port>, with IPv6 addresses in brackets. Read-only.

=head1 CONSTRUCTORS

=head2 new(%fields)

Dies if a field fails validation; see L</validation_errors> to check first.

=head2 from_spec($spec, %defaults)

Parses C<[udp:|tcp:]host[:port]>, with IPv6 addresses in brackets. C<%defaults>
supplies other attributes, such as C<interval>. Dies if C<$spec> is malformed.

=head1 CLASS METHODS

=head2 validation_errors(\%fields)

Returns a hash reference mapping each invalid, unknown or missing field name to
a description of the problem. It is empty when C<\%fields> would construct a
valid target.

=head1 METHODS

=head2 uri

The target's SIP URI, used as the request URI and in the C<To> header.

=head2 to_hash

A plain hash of the target's attributes, C<id> and C<uri>, for serialisation.

=cut
