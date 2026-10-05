use v5.40;
use Test2::V0;
use HTTP::Request::Common qw(DELETE GET POST PUT);
use IO::Async::Loop;
use JSON::PP qw(decode_json);
use Plack::Test;

use Sipping::API;
use Sipping::Monitor;
use Sipping::ProbeResult;

my $loop    = IO::Async::Loop->new;
my $monitor = Sipping::Monitor->new(loop => $loop);
my $app     = Plack::Test->create(Sipping::API->new(monitor => $monitor)->to_app);

sub post_json ($body) {
    return $app->request(POST '/targets', 'Content-Type' => 'application/json', Content => $body);
}

sub problem ($response) {
    is $response->content_type, 'application/problem+json', 'problem content type';
    return decode_json($response->content);
}

subtest 'GET /health' => sub {
    my $response = $app->request(GET '/health');
    is $response->code, 200, 'status';
    is decode_json($response->content), {status => 'ok'}, 'body';
};

subtest 'POST /targets creates a target' => sub {
    my $response = post_json('{"host": "pbx.example.com", "transport": "tcp", "interval": 3600}');
    is $response->code,               201,                                 'status';
    is $response->header('Location'), '/targets/tcp:pbx.example.com:5060', 'Location';
    is(
        decode_json($response->content),
        {
            id         => 'tcp:pbx.example.com:5060',
            host       => 'pbx.example.com',
            port       => 5060,
            transport  => 'tcp',
            interval   => 3600,
            uri        => 'sip:pbx.example.com:5060;transport=tcp',
            last_probe => undef,
            probes     => {up   => 0, down => 0},
            links      => {self => '/targets/tcp:pbx.example.com:5060'},
        },
        'body'
    );
    ok $monitor->has_target('tcp:pbx.example.com:5060'), 'monitor has the target';
};

subtest 'POST /targets rejects bad requests' => sub {
    my $conflict = post_json('{"host": "pbx.example.com", "transport": "tcp"}');
    is $conflict->code, 409, 'duplicate is a conflict';
    is $conflict->header('Location'), '/targets/tcp:pbx.example.com:5060',
        'conflict points at the existing target';

    my $invalid = post_json('{"host": "pbx", "port": 70000}');
    is $invalid->code, 422, 'invalid field';
    is problem($invalid)->{errors}, {port => 'must be an integer from 1 to 65535'}, 'per-field errors';

    is post_json('{not json')->code,                          400, 'malformed JSON';
    is post_json('[1, 2]')->code,                             400, 'JSON that is not an object';
    is $app->request(POST '/targets', [host => 'pbx'])->code, 415, 'form-encoded body';
};

subtest 'GET /targets/{id}' => sub {
    $monitor->record_result(
        Sipping::ProbeResult->new(
            target_id  => 'tcp:pbx.example.com:5060',
            state      => 'up',
            code       => 200,
            reason     => 'OK',
            rtt        => 0.0123,
            checked_at => 1_790_000_000,
        )
    );
    my $response = $app->request(GET '/targets/tcp:pbx.example.com:5060');
    is $response->code, 200, 'status';
    is(
        decode_json($response->content)->{last_probe},
        {
            state      => 'up',
            code       => 200,
            reason     => 'OK',
            rtt_ms     => 12.3,
            checked_at => '2026-09-21T14:13:20Z',
        },
        'includes the last probe'
    );

    my $missing = $app->request(GET '/targets/udp:nowhere:5060');
    is $missing->code,              404,                          'unknown target';
    is problem($missing)->{detail}, 'no target udp:nowhere:5060', 'detail';
};

subtest 'GET /targets' => sub {
    my $body = decode_json($app->request(GET '/targets')->content);
    is [map { $_->{id} } $body->{targets}->@*], ['tcp:pbx.example.com:5060'], 'lists targets';
};

subtest 'GET /metrics' => sub {
    my $response = $app->request(GET '/metrics');
    is $response->code, 200, 'status';
    like $response->content_type, qr{\Atext/plain}, 'Prometheus text format';
    my $body = $response->content;
    like $body, qr/^sipping_up\{target="tcp:pbx.example.com:5060"\} 1$/m,               'sipping_up';
    like $body, qr/^sipping_rtt_seconds\{target="tcp:pbx.example.com:5060"\} 0.0123$/m, 'sipping_rtt_seconds';
    like $body, qr/^sipping_response_code\{target="tcp:pbx.example.com:5060"\} 200$/m,
        'sipping_response_code';
    like $body, qr/^sipping_probes_total\{state="up",target="tcp:pbx.example.com:5060"\} 1$/m,
        'sipping_probes_total';
};

subtest 'DELETE /targets/{id}' => sub {
    is $app->request(DELETE '/targets/tcp:pbx.example.com:5060')->code, 204, 'deletes';
    is $app->request(DELETE '/targets/tcp:pbx.example.com:5060')->code, 404, 'then it is gone';
    ok !$monitor->has_target('tcp:pbx.example.com:5060'), 'monitor no longer has it';
};

subtest 'routing errors' => sub {
    my $unsupported = $app->request(PUT '/targets');
    is $unsupported->code,                  405,         'unsupported method';
    is $unsupported->header('Allow'),       'GET, POST', 'Allow header';
    is $app->request(GET '/nowhere')->code, 404,         'unknown path';
};

done_testing;
