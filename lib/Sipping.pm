package Sipping;

use v5.40;

our $VERSION = '0.01';

1;

__END__

=head1 NAME

Sipping - SIP OPTIONS health monitor with a REST API

=head1 SYNOPSIS

    use IO::Async::Loop;
    use Sipping::Monitor;
    use Sipping::Target;

    my $loop    = IO::Async::Loop->new;
    my $monitor = Sipping::Monitor->new(loop => $loop);
    $monitor->add_target(Sipping::Target->from_spec('udp:pbx.example.com:5060'));
    $loop->run;

=head1 DESCRIPTION

Sipping periodically sends SIP C<OPTIONS> requests to a set of endpoints and
reports each endpoint's reachability and round-trip time over a REST API and
as Prometheus metrics.

=over 4

=item L<Sipping::Message> - builds and parses SIP messages

=item L<Sipping::Target> - an endpoint to probe

=item L<Sipping::Prober> - sends one C<OPTIONS> probe over UDP or TCP

=item L<Sipping::ProbeResult> - the outcome of one probe

=item L<Sipping::Monitor> - schedules probes and keeps their results

=item L<Sipping::API> - the PSGI application serving the REST API

=back

=head1 AUTHOR

Martin Cowie

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
