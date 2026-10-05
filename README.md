# sipping

[![CI](https://github.com/martin-cowie/sipping/actions/workflows/ci.yml/badge.svg)](https://github.com/martin-cowie/sipping/actions/workflows/ci.yml)

A SIP health monitor in modern Perl. It sends SIP `OPTIONS` requests to a set
of endpoints on a schedule and reports each endpoint's state and round-trip
time over a REST API and as Prometheus metrics.

```console
$ bin/sipping --target udp:pbx.example.com --target tcp:proxy.example.com:5060
2026-10-05T10:19:17Z listening on http://127.0.0.1:8080/
2026-10-05T10:19:17Z udp:pbx.example.com:5060 is UP (200 OK)
2026-10-05T10:19:17Z tcp:proxy.example.com:5060 is UP (404 Not Found)
```

## Quick start

Requires Perl 5.40 or later and [cpm](https://metacpan.org/pod/App::cpm).

```console
$ make deps          # installs CPAN dependencies into ./local
$ make test
$ bin/sipping --help
```

Or with Docker:

```console
$ docker build -t sipping .
$ docker run -p 8080:8080 sipping --target udp:pbx.example.com
```

`contrib/sipping.service` is a hardened systemd unit for running it as a
service.

## REST API

| Method   | Path              | Purpose                                             |
|----------|-------------------|-----------------------------------------------------|
| `GET`    | `/targets`        | All targets with their latest probe and probe counts |
| `POST`   | `/targets`        | Start monitoring a target                           |
| `GET`    | `/targets/{id}`   | One target                                          |
| `DELETE` | `/targets/{id}`   | Stop monitoring a target                            |
| `GET`    | `/metrics`        | Prometheus metrics                                  |
| `GET`    | `/health`         | Liveness of sipping itself                          |

A target's id is `transport:host:port`, so it is predictable and two requests
for the same endpoint refer to the same resource.

```console
$ curl -si localhost:8080/targets -H 'Content-Type: application/json' \
       -d '{"host": "pbx.example.com", "transport": "tcp", "interval": 10}'
HTTP/1.1 201 Created
Location: /targets/tcp:pbx.example.com:5060
Content-Type: application/json

{
  "host" : "pbx.example.com",
  "id" : "tcp:pbx.example.com:5060",
  "interval" : 10,
  "last_probe" : null,
  "links" : {
    "self" : "/targets/tcp:pbx.example.com:5060"
  },
  "port" : 5060,
  "probes" : {
    "down" : 0,
    "up" : 0
  },
  "transport" : "tcp",
  "uri" : "sip:pbx.example.com:5060;transport=tcp"
}
```

After the first probe, `last_probe` holds the outcome:

```json
{
  "checked_at" : "2026-10-05T10:19:19Z",
  "code" : 200,
  "reason" : "OK",
  "rtt_ms" : 3.7,
  "state" : "up"
}
```

Errors use [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem details,
with a field-by-field `errors` object when validation fails:

```console
$ curl -s localhost:8080/targets -H 'Content-Type: application/json' \
       -d '{"host": "pbx.example.com", "port": 70000, "transport": "sctp"}'
{
  "detail" : "target is invalid",
  "errors" : {
    "port" : "must be an integer from 1 to 65535",
    "transport" : "must be \"udp\" or \"tcp\""
  },
  "status" : 422,
  "title" : "Unprocessable Content",
  "type" : "about:blank"
}
```

| Status | When                                                         |
|--------|--------------------------------------------------------------|
| 400    | The body is not a JSON object                                |
| 404    | No such target or path                                       |
| 405    | Unsupported method; the `Allow` header lists the supported ones |
| 409    | The target already exists; `Location` points at it          |
| 415    | The body is not `application/json`                           |
| 422    | A field is missing, unknown or invalid                       |

## Metrics

```
sipping_up{target="udp:pbx.example.com:5060"} 1
sipping_rtt_seconds{target="udp:pbx.example.com:5060"} 0.001776
sipping_response_code{target="udp:pbx.example.com:5060"} 200
sipping_probes_total{state="up",target="udp:pbx.example.com:5060"} 4
sipping_probes_total{state="down",target="udp:pbx.example.com:5060"} 0
```

## Design notes

- **Asynchronous throughout.** One [IO::Async](https://metacpan.org/pod/IO::Async)
  event loop runs the probes and the HTTP server; probe logic is written with
  [Future::AsyncAwait](https://metacpan.org/pod/Future::AsyncAwait), so the
  network code reads sequentially without blocking.
- **RFC 3261 retransmission.** Over UDP an unanswered request is retransmitted
  after T1 (500 ms), doubling up to T2 (4 s), within the same transaction
  branch, until the probe times out.
- **Stream framing.** Over TCP, responses are framed by `Content-Length`, and
  CRLF keep-alives are skipped.
- **Matching.** Only a final response with the request's `Call-ID` and `CSeq`
  completes a probe; provisional (1xx) responses are ignored.
- **What counts as up.** Any final response, including `404` or `503`, proves
  that a SIP stack is answering, so the target is up and the code is reported.
  Timeouts, refused connections and resolution failures are down.
- **No overlapping probes.** If a target's previous probe is still in flight
  when the next is due, the next is skipped.
- **Immutable values.** Targets, messages and probe results are read-only
  [Moo](https://metacpan.org/pod/Moo) objects validated with
  [Type::Tiny](https://metacpan.org/pod/Type::Tiny); the monitor owns all
  mutable state.

## Development

```console
$ make test          # Test2::V0 suite, including UDP and TCP against a fake SIP server
$ make lint          # Perl::Critic and Perl::Tidy
$ make tidy          # reformat in place
```

Each module documents its interface in POD: `perldoc lib/Sipping/Prober.pm`.

## Licence

Same terms as Perl itself.
