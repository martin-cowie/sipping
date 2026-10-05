package Sipping::ProbeResult;

use v5.40;
use Moo;
use POSIX           qw(strftime);
use Types::Standard qw(Enum Int Maybe Num Str);

has target_id  => (is => 'ro', isa => Str, required => 1);
has state      => (is => 'ro', isa => Enum [qw(up down)], required => 1);
has code       => (is => 'ro', isa => Maybe [Int]);
has reason     => (is => 'ro', isa => Str, required => 1);
has rtt        => (is => 'ro', isa => Maybe [Num]);
has checked_at => (is => 'ro', isa => Num, required => 1);

sub is_up ($self) {
    return $self->state eq 'up';
}

sub to_hash ($self) {
    return {
        state      => $self->state,
        code       => defined $self->code ? 0 + $self->code : undef,
        reason     => $self->reason,
        rtt_ms     => defined $self->rtt ? 0 + sprintf('%.1f', $self->rtt * 1000) : undef,
        checked_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $self->checked_at),
    };
}

1;

__END__

=head1 NAME

Sipping::ProbeResult - the outcome of one OPTIONS probe

=head1 DESCRIPTION

An immutable record of a single probe. A target is C<up> if it sent any final
response: even C<404> or C<503> proves that a SIP stack is listening, and the
code is recorded so that callers can draw finer distinctions.

=head1 ATTRIBUTES

=head2 target_id

The L<Sipping::Target> C<id> probed.

=head2 state

C<up> or C<down>.

=head2 code

The final response's status code, or C<undef> if none arrived.

=head2 reason

The response's reason phrase, or why the probe failed, such as C<Timeout>.

=head2 rtt

Seconds from sending the request to receiving the final response, or C<undef>.

=head2 checked_at

Epoch seconds when the probe started.

=head1 METHODS

=head2 is_up

True if C<state> is C<up>.

=head2 to_hash

A plain hash for serialisation, with C<rtt_ms> in milliseconds and
C<checked_at> in ISO 8601 UTC.

=cut
