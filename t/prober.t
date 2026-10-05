use v5.40;
use Test2::V0;
use IO::Async::Loop;
use IO::Socket::IP;

use Sipping::Prober;
use Sipping::Target;
use Sipping::Test::FakeSipServer;

my $loop = IO::Async::Loop->new;

sub probe_fake_server (%server_args) {
    my $server = Sipping::Test::FakeSipServer->new(loop => $loop, %server_args);
    my $target = Sipping::Target->new(
        host      => '127.0.0.1',
        port      => $server->port,
        transport => $server_args{transport} // 'udp',
    );
    my $prober = Sipping::Prober->new(loop => $loop, timeout => 1.5);
    return ($prober->probe($target)->get, $server);
}

for my $transport (qw(udp tcp)) {
    subtest "$transport: a 200 OK is up" => sub {
        my ($result, $server) = probe_fake_server(transport => $transport);
        is $result->state,  'up', 'state';
        is $result->code,   200,  'code';
        is $result->reason, 'OK', 'reason';
        ok $result->rtt > 0 && $result->rtt < 1.5, 'round-trip time';
        is $result->target_id, "$transport:127.0.0.1:" . $server->port, 'target_id';

        my ($request) = $server->received->@*;
        is $request->request_method, 'OPTIONS', 'server received OPTIONS';
        like $request->header('Via'), qr{\ASIP/2\.0/\U$transport\E 127\.0\.0\.1:\d+;branch=z9hG4bK}, 'Via';
    };

    subtest "$transport: any final response is up" => sub {
        my ($result) = probe_fake_server(transport => $transport, respond_with => [503]);
        is $result->state,  'up',                  'state';
        is $result->code,   503,                   'code';
        is $result->reason, 'Service Unavailable', 'reason';
    };

    subtest "$transport: provisional responses are skipped" => sub {
        my ($result) = probe_fake_server(transport => $transport, respond_with => [100, 200]);
        is $result->code, 200, 'waits for the final response';
    };

    subtest "$transport: silence is down" => sub {
        my ($result) = probe_fake_server(transport => $transport, respond_with => []);
        is $result->state,  'down',    'state';
        is $result->reason, 'Timeout', 'reason';
        is $result->code,   undef,     'no code';
        is $result->rtt,    undef,     'no round-trip time';
    };
}

subtest 'udp: unanswered requests are retransmitted' => sub {
    my ($result, $server) = probe_fake_server(ignore_first => 1);
    is $result->state,               'up', 'answered after retransmission';
    is scalar $server->received->@*, 2,    'server saw the request twice';
    is $server->received->[1]->header('Via'), $server->received->[0]->header('Via'),
        'retransmission reuses the transaction branch';
};

subtest 'tcp: a refused connection is down' => sub {
    my $closed_port = do {
        my $socket = IO::Socket::IP->new(LocalHost => '127.0.0.1', LocalPort => 0, Listen => 1) or die $@;
        $socket->sockport;
    };
    my $target = Sipping::Target->new(host => '127.0.0.1', port => $closed_port, transport => 'tcp');
    my $result = Sipping::Prober->new(loop => $loop)->probe($target)->get;
    is $result->state, 'down', 'state';
    like $result->reason, qr/Connection refused/, 'reason';
};

done_testing;
