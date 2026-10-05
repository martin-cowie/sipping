package Sipping::Test::FakeSipServer;

use v5.40;
use Moo;
use IO::Async::Listener;
use IO::Async::Socket;
use IO::Socket::IP;

use Sipping::Message;

my %REASON_FOR = (
    100 => 'Trying',
    200 => 'OK',
    404 => 'Not Found',
    503 => 'Service Unavailable',
);

has loop         => (is => 'ro', required => 1);
has transport    => (is => 'ro', default  => 'udp');
has respond_with => (is => 'ro', default  => sub { [200] });
has ignore_first => (is => 'ro', default  => 0);
has received     => (is => 'ro', default  => sub { [] });
has _notifier    => (is => 'lazy');

sub BUILD ($self, $) {
    $self->_notifier;
    return;
}

sub port ($self) {
    return $self->_notifier->read_handle->sockport;
}

sub _build__notifier ($self) {
    return $self->transport eq 'tcp' ? $self->_start_tcp : $self->_start_udp;
}

sub _start_udp ($self) {
    my $handle = IO::Socket::IP->new(LocalHost => '127.0.0.1', LocalPort => 0, Proto => 'udp')
        or die "cannot bind UDP socket: $@";
    my $socket = IO::Async::Socket->new(
        handle  => $handle,
        on_recv => sub ($socket, $datagram, $peer) {
            $socket->send($_, 0, $peer) for $self->_replies_to($datagram);
        },
    );
    $self->loop->add($socket);
    return $socket;
}

sub _start_tcp ($self) {
    my $listener = IO::Async::Listener->new(
        on_stream => sub ($listener, $stream) {
            $stream->configure(
                on_read => sub ($stream, $buffer_ref, $) {
                    while (defined(my $text = Sipping::Message->extract($buffer_ref))) {
                        $stream->write($_) for $self->_replies_to($text);
                    }
                    return 0;
                },
            );
            $listener->loop->add($stream);
        },
    );
    $self->loop->add($listener);
    $listener->listen(addr => {family => 'inet', socktype => 'stream', ip => '127.0.0.1', port => 0})->get;
    return $listener;
}

sub _replies_to ($self, $text) {
    my $request = Sipping::Message->parse($text);
    push $self->received->@*, $request;
    return if $self->received->@* <= $self->ignore_first;
    return map { _response_to($request, $_) } $self->respond_with->@*;
}

sub _response_to ($request, $code) {
    my $response = Sipping::Message->new(
        start_line => "SIP/2.0 $code $REASON_FOR{$code}",
        headers    => [
            (map { [$_, $request->header($_)] } qw(Via From To Call-ID CSeq)),
            ['Content-Length', '0'],
        ],
    );
    return $response->as_string;
}

1;

__END__

=head1 NAME

Sipping::Test::FakeSipServer - a scriptable SIP responder on 127.0.0.1

=head1 SYNOPSIS

    my $server = Sipping::Test::FakeSipServer->new(
        loop         => $loop,
        transport    => 'udp',
        respond_with => [100, 200],
        ignore_first => 1,
    );
    my $target = Sipping::Target->new(host => '127.0.0.1', port => $server->port);

=head1 DESCRIPTION

Listens on an ephemeral port and answers each request with the responses
listed in C<respond_with> (none means stay silent), after ignoring the first
C<ignore_first> requests. Every request received is kept in C<received>.

=cut
