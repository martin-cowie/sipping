use v5.40;
use Test2::V0;

use Sipping::Message;
use Sipping::Target;

my $CRLF = "\r\n";

subtest 'options_request builds an RFC 3261 OPTIONS request' => sub {
    my $request = Sipping::Message->options_request(
        target     => Sipping::Target->new(host => 'pbx.example.com', transport => 'tcp'),
        local_host => '192.0.2.10',
        local_port => 50_600,
        branch     => 'z9hG4bKabc',
        tag        => 'tag1',
        call_id    => 'call1@sipping',
        user_agent => 'sipping/test',
    );

    is $request->request_method, 'OPTIONS',                                                'method';
    is $request->start_line,     'OPTIONS sip:pbx.example.com:5060;transport=tcp SIP/2.0', 'request line';
    is $request->header('Via'),  'SIP/2.0/TCP 192.0.2.10:50600;branch=z9hG4bKabc;rport',   'Via';
    is $request->header('To'),   '<sip:pbx.example.com:5060;transport=tcp>',               'To';
    is $request->header('CSeq'), '1 OPTIONS',                                              'CSeq';
    is $request->header('content-length'), '0', 'Content-Length, looked up case-insensitively';

    my $wire = $request->as_string;
    like $wire,   qr/\r\n\r\n\z/, 'ends with an empty line';
    unlike $wire, qr/(?<!\r)\n/,  'every line ends with CRLF';
};

subtest 'parse reads a response' => sub {
    my $response = Sipping::Message->parse(
        join $CRLF,
        'SIP/2.0 200 OK',
        'v: SIP/2.0/UDP 192.0.2.10:5060;branch=z9hG4bKabc',
        'i: call1@sipping',
        'CSeq: 1',
        '  OPTIONS',
        'l: 0',
        '', ''
    );

    ok $response->is_response, 'is a response';
    is $response->status_code,             200,                                             'status code';
    is $response->reason_phrase,           'OK',                                            'reason phrase';
    is $response->header('Call-ID'),       'call1@sipping',                                 'compact Call-ID';
    is $response->header('Via'),           'SIP/2.0/UDP 192.0.2.10:5060;branch=z9hG4bKabc', 'compact Via';
    is $response->header('CSeq'),          '1 OPTIONS', 'folded header is unfolded';
    is $response->header('X-Not-Present'), undef,       'absent header is undef';
};

subtest 'parse rejects malformed messages' => sub {
    like dies { Sipping::Message->parse('') },                        qr/malformed SIP message/, 'empty';
    like dies { Sipping::Message->parse("HTTP/1.1 200 OK\r\n\r\n") }, qr/bad start line/,        'not SIP';
    like dies { Sipping::Message->parse("SIP/2.0 200 OK\r\nno colon\r\n\r\n") }, qr/malformed SIP header/,
        'bad header';
};

subtest 'extract frames messages on a stream' => sub {
    my $first  = "SIP/2.0 200 OK${CRLF}Content-Length: 5${CRLF}${CRLF}hello";
    my $second = "SIP/2.0 404 Not Found${CRLF}l: 0${CRLF}${CRLF}";
    my $buffer = "$CRLF$CRLF$first" . substr $second, 0, 10;

    is(Sipping::Message->extract(\$buffer), $first, 'skips keep-alives and extracts a message with a body');
    is(Sipping::Message->extract(\$buffer), undef,  'waits for a partial message');

    $buffer .= substr $second, 10;
    is(Sipping::Message->extract(\$buffer), $second, 'extracts it once complete');
    is $buffer, '', 'consumes the buffer';
};

done_testing;
