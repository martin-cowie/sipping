use v5.40;
use Test2::V0;

use Sipping::Target;

subtest 'defaults' => sub {
    my $target = Sipping::Target->new(host => 'pbx.example.com');
    is $target->port,      5060,                       'port';
    is $target->transport, 'udp',                      'transport';
    is $target->interval,  30,                         'interval';
    is $target->id,        'udp:pbx.example.com:5060', 'id';
    is $target->uri,       'sip:pbx.example.com:5060', 'uri';
};

subtest 'from_spec' => sub {
    my @cases = (
        ['pbx.example.com',        'udp:pbx.example.com:5060'],
        ['tcp:pbx.example.com',    'tcp:pbx.example.com:5060'],
        ['udp:192.0.2.1:5080',     'udp:192.0.2.1:5080'],
        ['tcp:[2001:db8::1]:5061', 'tcp:[2001:db8::1]:5061'],
    );
    for my $case (@cases) {
        my ($spec, $id) = $case->@*;
        is(Sipping::Target->from_spec($spec)->id, $id, $spec);
    }

    is(Sipping::Target->from_spec('pbx', interval => 5)->interval, 5,             'applies defaults');
    is(Sipping::Target->from_spec('[2001:db8::1]')->host,          '2001:db8::1', 'strips IPv6 brackets');
    is(
        Sipping::Target->from_spec('tcp:[2001:db8::1]')->uri, 'sip:[2001:db8::1]:5060;transport=tcp',
        'brackets IPv6 in the URI'
    );
    like dies { Sipping::Target->from_spec('sctp:pbx') }, qr/invalid target/, 'rejects unknown transport';
};

subtest 'validation_errors' => sub {
    is(
        Sipping::Target->validation_errors(
            {host => 'pbx', port => 5061, transport => 'tcp', interval => 0.5}
        ),
        {},
        'valid fields'
    );
    is(
        Sipping::Target->validation_errors({port => 0, transport => 'sctp', interval => -1, colour => 'red'}),
        {
            host      => 'is required',
            port      => 'must be an integer from 1 to 65535',
            transport => 'must be "udp" or "tcp"',
            interval  => 'must be a positive number of seconds',
            colour    => 'is not a recognised field',
        },
        'reports each problem'
    );
    is(
        Sipping::Target->validation_errors({host => 'bad host!'}),
        {host => 'must be a hostname or IP address'},
        'rejects a malformed host'
    );
};

subtest 'to_hash' => sub {
    is(
        Sipping::Target->from_spec('tcp:pbx:5061')->to_hash,
        {
            id        => 'tcp:pbx:5061',
            host      => 'pbx',
            port      => 5061,
            transport => 'tcp',
            interval  => 30,
            uri       => 'sip:pbx:5061;transport=tcp',
        },
    );
};

done_testing;
