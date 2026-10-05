package Sipping::Monitor;

use v5.40;
use Moo;
use IO::Async::Timer::Periodic;
use Types::Standard qw(CodeRef InstanceOf);

use Sipping::Prober;

has loop          => (is => 'ro',   isa => InstanceOf ['IO::Async::Loop'], required => 1);
has prober        => (is => 'lazy', isa => InstanceOf ['Sipping::Prober']);
has on_transition => (is => 'ro',   isa => CodeRef, predicate => 1);

has _targets => (is => 'ro', default => sub { {} });
has _timers  => (is => 'ro', default => sub { {} });
has _probes  => (is => 'ro', default => sub { {} });
has _results => (is => 'ro', default => sub { {} });
has _counts  => (is => 'ro', default => sub { {} });

sub _build_prober ($self) {
    return Sipping::Prober->new(loop => $self->loop);
}

sub add_target ($self, $target) {
    my $id = $target->id;
    die "target $id is already monitored\n" if $self->has_target($id);

    weaken(my $monitor = $self);
    my $timer = IO::Async::Timer::Periodic->new(
        interval       => $target->interval,
        first_interval => 0,
        on_tick        => sub { $monitor->_probe($target) },
    );
    $self->_targets->{$id} = $target;
    $self->_timers->{$id}  = $timer;
    $self->_counts->{$id}  = {up => 0, down => 0};
    $self->loop->add($timer);
    $timer->start;
    return $target;
}

sub remove_target ($self, $id) {
    return false unless $self->has_target($id);

    my $timer = delete $self->_timers->{$id};
    $self->loop->remove($timer);
    my $probe = delete $self->_probes->{$id};
    $probe->cancel if $probe;
    delete $self->_targets->{$id};
    delete $self->_results->{$id};
    delete $self->_counts->{$id};
    return true;
}

sub has_target ($self, $id) {
    return exists $self->_targets->{$id};
}

sub target ($self, $id) {
    return $self->_targets->{$id};
}

sub targets ($self) {
    my $targets = $self->_targets;
    return map { $targets->{$_} } sort keys $targets->%*;
}

sub result_for ($self, $id) {
    return $self->_results->{$id};
}

sub counts_for ($self, $id) {
    my $counts = $self->_counts->{$id} or return;
    return {$counts->%*};
}

sub record_result ($self, $result) {
    my $id = $result->target_id;
    return unless $self->has_target($id);

    my $previous = $self->_results->{$id};
    $self->_results->{$id} = $result;
    $self->_counts->{$id}{$result->state}++;
    $self->on_transition->($previous, $result)
        if $self->has_on_transition && (!$previous || $previous->state ne $result->state);
    return;
}

sub _probe ($self, $target) {
    my $id = $target->id;
    return if $self->_probes->{$id};

    my $probe = $self->prober->probe($target);
    $self->_probes->{$id} = $probe;
    $probe->on_done(sub ($result) { $self->record_result($result) });
    $probe->on_ready(sub { delete $self->_probes->{$id} });
    return;
}

1;

__END__

=head1 NAME

Sipping::Monitor - probe a set of targets on a schedule

=head1 SYNOPSIS

    my $monitor = Sipping::Monitor->new(
        loop          => $loop,
        on_transition => sub ($previous, $current) {
            warn $current->target_id, ' is ', $current->state, "\n";
        },
    );
    $monitor->add_target($target);
    $loop->run;

=head1 DESCRIPTION

Probes each target immediately on adding it, then every C<interval> seconds.
A target's probes never overlap: if one is still in flight when the next is
due, the next is skipped.

=head1 ATTRIBUTES

=head2 loop

The L<IO::Async::Loop> to schedule on. Required.

=head2 prober

The L<Sipping::Prober> to use. Defaults to one with default settings.

=head2 on_transition

Optional callback, called with the previous and current
L<Sipping::ProbeResult> when a target's state changes. The previous result is
C<undef> for a target's first probe.

=head1 METHODS

=head2 add_target($target)

Starts monitoring a L<Sipping::Target> and returns it. Dies if a target with
the same C<id> is already monitored.

=head2 remove_target($id)

Stops monitoring a target, cancelling any probe in flight and discarding its
results. Returns true if the target was being monitored.

=head2 has_target($id)

True if a target with this C<id> is monitored.

=head2 target($id)

The monitored target with this C<id>, or C<undef>.

=head2 targets

All monitored targets, ordered by C<id>.

=head2 result_for($id)

The target's latest L<Sipping::ProbeResult>, or C<undef> before its first
probe completes.

=head2 counts_for($id)

A hash reference of the target's completed probes by state, such as
C<< { up => 41, down => 1 } >>, or nothing if the target is not monitored.

=head2 record_result($result)

Stores a L<Sipping::ProbeResult> as its target's latest and calls
C<on_transition> if the state changed. Results for targets no longer monitored
are ignored.

=cut
