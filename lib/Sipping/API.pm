package Sipping::API;

use v5.40;
use Moo;
use JSON::PP ();
use Plack::Request;
use Types::Standard qw(InstanceOf);

use Sipping::Target;

my %TITLE_FOR = (
    400 => 'Bad Request',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    409 => 'Conflict',
    415 => 'Unsupported Media Type',
    422 => 'Unprocessable Content',
);

my @ROUTES = (
    [qr{\A/health\z},          {GET => \&_health}],
    [qr{\A/targets\z},         {GET => \&_list_targets, POST   => \&_create_target}],
    [qr{\A/targets/([^/]+)\z}, {GET => \&_show_target,  DELETE => \&_delete_target}],
    [qr{\A/metrics\z},         {GET => \&_metrics}],
);

has monitor => (is => 'ro', isa => InstanceOf ['Sipping::Monitor'], required => 1);
has _json => (is => 'lazy', default => sub { JSON::PP->new->utf8->canonical->pretty->indent_length(2) });

sub to_app ($self) {
    return sub ($env) { $self->_dispatch(Plack::Request->new($env)) };
}

sub _dispatch ($self, $request) {
    my $path = $request->path_info;
    for my $route (@ROUTES) {
        my ($pattern, $handler_for) = $route->@*;
        next unless $path =~ $pattern;
        my @captures = @{^CAPTURE};
        my $handler  = $handler_for->{$request->method} // return $self->_problem(
            405, "$path does not support " . $request->method,
            headers => [Allow => join ', ', sort keys $handler_for->%*]
        );
        return $self->$handler($request, @captures);
    }
    return $self->_problem(404, "no resource at $path");
}

sub _health ($self, $) {
    return $self->_json_response(200, {status => 'ok'});
}

sub _list_targets ($self, $) {
    my @targets = map { $self->_representation($_) } $self->monitor->targets;
    return $self->_json_response(200, {targets => \@targets});
}

sub _show_target ($self, $, $id) {
    my $target = $self->monitor->target($id) or return $self->_problem(404, "no target $id");
    return $self->_json_response(200, $self->_representation($target));
}

sub _create_target ($self, $request) {
    return $self->_problem(415, 'request body must be application/json')
        unless ($request->content_type // '') =~ m{\Aapplication/json\b}i;

    my $fields = $self->_decode($request->content);
    return $self->_problem(400, 'request body must be a JSON object') unless ref $fields eq 'HASH';

    my $errors = Sipping::Target->validation_errors($fields);
    return $self->_problem(422, 'target is invalid', errors => $errors) if $errors->%*;

    my $target = Sipping::Target->new($fields->%*);
    return $self->_problem(
        409, sprintf('target %s already exists', $target->id),
        headers => [Location => _location($target)]
    ) if $self->monitor->has_target($target->id);

    $self->monitor->add_target($target);
    return $self->_json_response(201, $self->_representation($target), Location => _location($target));
}

sub _delete_target ($self, $, $id) {
    return $self->monitor->remove_target($id) ? [204, [], []] : $self->_problem(404, "no target $id");
}

sub _metrics ($self, $) {
    my @targets = $self->monitor->targets;
    my @results = grep { defined } map { $self->monitor->result_for($_->id) } @targets;
    my @lines   = (
        '# HELP sipping_up Whether the target sent a final response to its last OPTIONS probe.',
        '# TYPE sipping_up gauge',
        (map { _sample('sipping_up', {target => $_->target_id}, $_->is_up ? 1 : 0) } @results),
        '# HELP sipping_rtt_seconds Round-trip time of the last successful probe.',
        '# TYPE sipping_rtt_seconds gauge',
        (
            map  { _sample('sipping_rtt_seconds', {target => $_->target_id}, 0 + sprintf('%.6f', $_->rtt)) }
            grep { $_->is_up } @results
        ),
        '# HELP sipping_response_code Status code of the last final response.',
        '# TYPE sipping_response_code gauge',
        (
            map  { _sample('sipping_response_code', {target => $_->target_id}, $_->code) }
            grep { $_->is_up } @results
        ),
        '# HELP sipping_probes_total Probes completed, by outcome.',
        '# TYPE sipping_probes_total counter',
        (map { $self->_probe_count_samples($_->id) } @targets),
    );
    return [200, ['Content-Type' => 'text/plain; version=0.0.4; charset=utf-8'], [join("\n", @lines) . "\n"]];
}

sub _probe_count_samples ($self, $id) {
    my $counts = $self->monitor->counts_for($id);
    return map { _sample('sipping_probes_total', {target => $id, state => $_}, $counts->{$_}) } qw(up down);
}

sub _representation ($self, $target) {
    my $last_probe = $self->monitor->result_for($target->id);
    return {
        $target->to_hash->%*,
        last_probe => $last_probe ? $last_probe->to_hash : undef,
        probes     => $self->monitor->counts_for($target->id),
        links      => {self => _location($target)},
    };
}

sub _decode ($self, $text) {
    my $result = eval { $self->_json->decode($text) };
    return $result;
}

sub _json_response ($self, $status, $body, @headers) {
    return [$status, ['Content-Type' => 'application/json', @headers], [$self->_json->encode($body)]];
}

sub _problem ($self, $status, $detail, %options) {
    my $body = {
        type   => 'about:blank',
        title  => $TITLE_FOR{$status},
        status => $status,
        detail => $detail,
        ($options{errors} ? (errors => $options{errors}) : ()),
    };
    return [
        $status,
        ['Content-Type' => 'application/problem+json', ($options{headers} // [])->@*],
        [$self->_json->encode($body)],
    ];
}

sub _location ($target) {
    return '/targets/' . ($target->id =~ s{([^A-Za-z0-9\-._~!\$&'()*+,;=:@])}{sprintf '%%%02X', ord $1}ger);
}

sub _sample ($name, $labels, $value) {
    my $label_text = join ',',
        map { sprintf '%s="%s"', $_, _escape_label($labels->{$_}) } sort keys $labels->%*;
    return "$name\{$label_text\} $value";
}

sub _escape_label ($value) {
    return $value =~ s/(["\\])/\\$1/gr =~ s/\n/\\n/gr;
}

1;

__END__

=head1 NAME

Sipping::API - REST API for a Sipping::Monitor, as a PSGI application

=head1 SYNOPSIS

    my $app = Sipping::API->new(monitor => $monitor)->to_app;

=head1 DESCRIPTION

Exposes a L<Sipping::Monitor> over HTTP. Success responses are
C<application/json>; errors are RFC 9457 C<application/problem+json>.

=over 4

=item C<GET /targets>

Lists every target with its latest probe result and probe counts.

=item C<POST /targets>

Adds a target from a JSON object with C<host> and optionally C<port>,
C<transport> and C<interval>. Responds C<201 Created> with a C<Location>
header, C<409 Conflict> if the target already exists, C<415> unless the body
is JSON and C<422> with per-field C<errors> if it is invalid.

=item C<GET /targets/{id}>

One target, or C<404>.

=item C<DELETE /targets/{id}>

Stops monitoring a target: C<204 No Content>, or C<404>.

=item C<GET /metrics>

Prometheus text exposition: C<sipping_up>, C<sipping_rtt_seconds>,
C<sipping_response_code> and C<sipping_probes_total>.

=item C<GET /health>

The service's own liveness.

=back

Unsupported methods on a known path get C<405> with an C<Allow> header.

=head1 ATTRIBUTES

=head2 monitor

The L<Sipping::Monitor> to expose. Required.

=head1 METHODS

=head2 to_app

Returns the PSGI application code reference.

=cut
