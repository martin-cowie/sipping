use v5.40;
use Test2::V0;
use IO::Async::Loop;

use Sipping::Monitor;
use Sipping::Prober;
use Sipping::ProbeResult;
use Sipping::Target;
use Sipping::Test::FakeSipServer;

my $loop = IO::Async::Loop->new;

sub result_for ($state, $target_id = 'udp:pbx:5060') {
    return Sipping::ProbeResult->new(
        target_id  => $target_id,
        state      => $state,
        reason     => $state,
        checked_at => time,
    );
}

subtest 'probes a target on a schedule' => sub {
    my $server = Sipping::Test::FakeSipServer->new(loop => $loop);
    my $target = Sipping::Target->new(host => '127.0.0.1', port => $server->port, interval => 0.2);
    my @transitions;
    my $monitor = Sipping::Monitor->new(
        loop          => $loop,
        prober        => Sipping::Prober->new(loop => $loop, timeout => 0.5),
        on_transition => sub ($previous, $current) { push @transitions, [$previous, $current] },
    );

    $monitor->add_target($target);
    $loop->delay_future(after => 0.5)->get;

    ok $monitor->result_for($target->id)->is_up, 'target is up';
    cmp_ok scalar $server->received->@*, '>=', 2, 'probed repeatedly';
    is $monitor->counts_for($target->id)->{up}, scalar $server->received->@*, 'counts every probe';
    is scalar @transitions,                     1,                            'one transition: unknown to up';
    is $transitions[0][0],                      undef, 'first transition has no previous result';

    ok $monitor->remove_target($target->id), 'removes the target';
    my $probes_so_far = scalar $server->received->@*;
    $loop->delay_future(after => 0.5)->get;
    is scalar $server->received->@*, $probes_so_far, 'stops probing after removal';
};

subtest 'manages targets' => sub {
    my $monitor  = Sipping::Monitor->new(loop => $loop);
    my $b_target = Sipping::Target->new(host => 'b.invalid', interval => 3600);
    my $a_target = Sipping::Target->new(host => 'a.invalid', interval => 3600);

    $monitor->add_target($_) for $b_target, $a_target;
    is [map { $_->id } $monitor->targets], [$a_target->id, $b_target->id], 'targets are ordered by id';
    ok $monitor->has_target($a_target->id), 'has_target';
    is $monitor->target($a_target->id), $a_target, 'target';
    like dies { $monitor->add_target($a_target) }, qr/already monitored/, 'rejects a duplicate';

    ok !$monitor->remove_target('udp:nowhere:5060'), 'removing an unknown target is false';
    $monitor->remove_target($_->id) for $a_target, $b_target;
    is [$monitor->targets], [], 'all removed';
};

subtest 'record_result reports transitions only on change' => sub {
    my @transitions;
    my $monitor = Sipping::Monitor->new(
        loop          => $loop,
        on_transition => sub ($previous, $current) { push @transitions, $current->state },
    );
    my $target = $monitor->add_target(Sipping::Target->new(host => 'pbx', interval => 3600));

    $monitor->record_result(result_for($_)) for qw(up up down down up);
    is \@transitions, [qw(up down up)], 'transitions';
    is $monitor->counts_for($target->id), {up => 3, down => 2}, 'counts';

    $monitor->record_result(result_for('up', 'udp:other:5060'));
    is $monitor->result_for('udp:other:5060'), undef, 'ignores results for unknown targets';
    $monitor->remove_target($target->id);
};

done_testing;
