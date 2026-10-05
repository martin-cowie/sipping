package Sipping::Prober;

use v5.40;
use Moo;
use Future;
use Future::AsyncAwait;
use IO::Async::Socket;
use IO::Async::Stream;
use List::Util             qw(min);
use Time::HiRes            ();
use Types::Common::Numeric qw(PositiveNum);
use Types::Standard        qw(InstanceOf Str);

use Sipping;
use Sipping::Message;
use Sipping::ProbeResult;

# RFC 3261 section 17.1.2.2: non-INVITE requests over UDP are retransmitted
# after T1, doubling each time up to T2.
use constant {
    T1 => 0.5,
    T2 => 4,
};

has loop       => (is => 'ro', isa => InstanceOf ['IO::Async::Loop'], required => 1);
has timeout    => (is => 'ro', isa => PositiveNum, default => 2);
has user_agent => (is => 'ro', isa => Str,         default => sub { "sipping/$Sipping::VERSION" });

async sub probe ($self, $target) {
    my $started = Time::HiRes::time();
    try {
        my $response = await Future->wait_any(
            $self->_exchange($target),
            $self->loop->timeout_future(after => $self->timeout),
        );
        return Sipping::ProbeResult->new(
            target_id  => $target->id,
            state      => 'up',
            code       => $response->status_code,
            reason     => $response->reason_phrase,
            rtt        => Time::HiRes::time() - $started,
            checked_at => $started,
        );
    }
    catch ($error) {
        return Sipping::ProbeResult->new(
            target_id  => $target->id,
            state      => 'down',
            reason     => _describe($error),
            checked_at => $started,
        );
    }
}

sub _exchange ($self, $target) {
    return $target->transport eq 'tcp' ? $self->_exchange_tcp($target) : $self->_exchange_udp($target);
}

async sub _exchange_udp ($self, $target) {
    my $handle = await $self->loop->connect(
        host     => $target->host,
        service  => $target->port,
        socktype => 'dgram',
    );
    my $request  = $self->_request($target, $handle);
    my $response = $self->loop->new_future;
    my $socket   = IO::Async::Socket->new(
        handle        => $handle,
        on_recv       => sub ($, $datagram, $) { _accept($response, $request, $datagram) },
        on_recv_error => sub ($, $errno) { _fail($response, $errno) },
    );
    $self->loop->add($socket);

    $socket->send($request->as_string);
    my $retransmission = $self->_retransmit($socket, $request->as_string, T1);
    $response->on_ready(sub { $retransmission->cancel; $socket->close });
    return await $response;
}

sub _retransmit ($self, $socket, $datagram, $interval) {
    return $self->loop->delay_future(after => $interval)->then(
        sub {
            $socket->send($datagram);
            return $self->_retransmit($socket, $datagram, min($interval * 2, T2));
        }
    );
}

async sub _exchange_tcp ($self, $target) {
    my $handle = await $self->loop->connect(
        host     => $target->host,
        service  => $target->port,
        socktype => 'stream',
    );
    my $request  = $self->_request($target, $handle);
    my $response = $self->loop->new_future;
    my $stream   = IO::Async::Stream->new(
        handle  => $handle,
        on_read => sub ($, $buffer_ref, $eof) {
            while (defined(my $text = Sipping::Message->extract($buffer_ref))) {
                _accept($response, $request, $text);
            }
            _fail($response, 'Connection closed by peer') if $eof;
            return 0;
        },
        on_read_error  => sub ($, $errno) { _fail($response, $errno) },
        on_write_error => sub ($, $errno) { _fail($response, $errno) },
    );
    $self->loop->add($stream);

    $response->on_ready(sub { $stream->close_now });
    $stream->write($request->as_string);
    return await $response;
}

sub _request ($self, $target, $handle) {
    return Sipping::Message->options_request(
        target     => $target,
        local_host => $handle->sockhost,
        local_port => $handle->sockport,
        branch     => 'z9hG4bK' . _token(),
        tag        => _token(),
        call_id    => _token() . '@sipping',
        user_agent => $self->user_agent,
    );
}

sub _accept ($response, $request, $text) {
    return if $response->is_ready;
    try {
        my $message = Sipping::Message->parse($text);
        return unless $message->is_response && _answers($message, $request) && $message->status_code >= 200;
        $response->done($message);
    }
    catch ($error) {
        return;
    }
    return;
}

sub _answers ($response, $request) {
    return ($response->header('Call-ID') // '') eq $request->header('Call-ID')
        && ($response->header('CSeq') // '') eq $request->header('CSeq');
}

sub _fail ($response, $reason) {
    $response->fail("$reason") unless $response->is_ready;
    return;
}

sub _describe ($error) {
    return "$error" =~ s/ at \S+ line \d+\.?\s*\z//r =~ s/\s+\z//r;
}

sub _token {
    return sprintf '%08x%08x', int rand 0xFFFF_FFFF, int rand 0xFFFF_FFFF;
}

1;

__END__

=head1 NAME

Sipping::Prober - send one SIP OPTIONS probe over UDP or TCP

=head1 SYNOPSIS

    my $prober = Sipping::Prober->new(loop => $loop, timeout => 2);
    my $result = await $prober->probe($target);
    say $result->state;

=head1 DESCRIPTION

Sends an C<OPTIONS> request to a L<Sipping::Target> and waits for a matching
final response, ignoring provisional (1xx) responses and anything with a
different C<Call-ID> or C<CSeq>.

Over UDP the request is retransmitted using the RFC 3261 timers (T1 = 500 ms,
doubling to a ceiling of T2 = 4 s) until a response arrives or the timeout
expires. Over TCP, responses are framed by C<Content-Length>.

=head1 ATTRIBUTES

=head2 loop

The L<IO::Async::Loop> to run on. Required.

=head2 timeout

Seconds to wait for a final response, including connection set-up and name
resolution. Defaults to 2.

=head2 user_agent

The C<User-Agent> header value. Defaults to C<sipping/$VERSION>.

=head1 METHODS

=head2 probe($target)

Returns a L<Future> that always succeeds, with a L<Sipping::ProbeResult>: C<up>
with the response code and round-trip time, or C<down> with the reason, such
as C<Timeout> or C<connect: Connection refused>. Cancelling the future
abandons the probe and closes its socket.

=cut
