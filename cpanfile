requires 'perl', '5.040';

requires 'Future',                   '0.50';
requires 'Future::AsyncAwait',       '0.66';
requires 'IO::Async',                '0.802';
requires 'JSON::PP',                 '4.0';
requires 'Moo',                      '2.005';
requires 'Net::Async::HTTP::Server', '0.14';
requires 'Plack',                    '1.0050';
requires 'Type::Tiny',               '2.0';

on test => sub {
    requires 'HTTP::Request::Common';
    requires 'Test2::V0', '0.000159';
};

on develop => sub {
    requires 'Perl::Critic', '1.152';
    requires 'Perl::Tidy',   '== 20260826';
};
