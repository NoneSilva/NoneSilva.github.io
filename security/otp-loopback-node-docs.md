---
title: "Erlang/OTP: documenting how to bind a distributed node to loopback"
---

# Erlang/OTP: documenting how to bind a distributed node to loopback

*September 2026 — a documentation change proposed to Erlang/OTP,
[erlang/otp#11617](https://github.com/erlang/otp/pull/11617) (target `maint`).
Measurements: [erts-sched/otp-loopback-node-measurements](https://github.com/erts-sched/otp-loopback-node-measurements).
Follows from the [VS Code Erlang extension RCE](../vscode-erlang-loopback-rce/).*

## Why

The [VS Code extension bug](../vscode-erlang-loopback-rce/) was one instance of
a class: a tool that only needs *local* Erlang distribution ships with the
cluster default instead — the distribution listener on all interfaces, `epmd`
on all interfaces, and a guessable cookie. The same shape produced
CVE-2022-24706 in Apache CouchDB (distribution reachable with the default
cookie `monster`).

The fix in each case is the same three settings. But nowhere in the OTP
documentation is it written down how to run a node confined to the local host,
which of the settings does what, or why the obvious attempts fail. The
`inet_dist_use_interface` entry in `kernel_app.md` was two sentences and only
mentioned hosts with "many network interfaces". So this is the general lesson
of the extension bug, taken upstream — not as a vulnerability report (Erlang
distribution is documented as not being for untrusted networks, and the cookie
is documented as not being a security mechanism; reporting that returns "by
design"), but as the missing page.

The PR does not change any default or behavior. It expands that one entry to
explain the recipe, what each setting does and does not do, the IPv6
equivalent, and the honest limit: binding to loopback removes the network
exposure, it does not replace the cookie.

## How it was measured

The obvious recipe (`-kernel inet_dist_use_interface {127,0,0,1}`) has traps
that only show up when you measure, not when you reason:

- The **node name alone binds nothing**. `-name mynode@127.0.0.1` on its own
  still listens on `0.0.0.0`. `inet_dist_use_interface` is what binds the
  socket.
- A **short name silently breaks the node's own remote shell** — sometimes.
  `-sname mynode` takes the host part from the machine's hostname, and whether
  that resolves to `127.0.0.1` depends on the machine: it did on the host
  measured, it resolved to the LAN address inside a bridged container, and to
  `127.0.1.1` on a Debian-style layout. With a loopback-bound listener, a name
  that resolves to any other address is refused. A name whose host part is a
  literal address needs no resolution and is the robust form.
- A **plain `erl -remsh` cannot reach the node**. Without `-name`/`-sname` the
  remote shell starts as a short-named node with a dynamic name, and a
  short-named node cannot connect to a long-named one. The working client is
  `erl -name shell@127.0.0.1 -dist_listen false -remsh mynode@127.0.0.1` — and
  without `-dist_listen false` that shell node itself listens on all
  interfaces while connected to the confined node.
- `ERL_EPMD_ADDRESS` **only affects an `epmd` this node starts**. An `epmd`
  already running (a system service) keeps the addresses it was started with,
  and the node registers with it silently; the node stays confined, but its
  name and port remain visible through `epmd`.
- **Binding restricts incoming connections only.** The confined node still
  connects *out*, and once connected the peer runs code back into it over that
  connection. Measured: a loopback-bound node connecting to a peer named on
  the LAN address, and the peer's `rpc:call` returning the node's own OS pid.

## Making the analysis reproducible

Every claim in the PR is one row in a table, and every row is a case in a
script anyone can run:
[otp-loopback-node-measurements](https://github.com/erts-sched/otp-loopback-node-measurements).
It reads sockets from inside the BEAM (`inet:sockname/1`,
`gen_tcp:connect/4` against `epmd`, `inet:getifaddrs/0`), not with `ss`, so the
only requirements are `bash`, `erl` and `epmd`. It runs on a private `epmd`
port so a system daemon is never touched, and cleans up every node on exit.

```
./measure.sh                 # every case, on the local OTP
./run-docker.sh 27 28 29     # official erlang:<v> images
```

Twenty-four cases, run on OTP 27.3.4.17, 28.5.0.6 and 29.0.6 (the version of
`maint`), IPv4 and IPv6, on the host and in containers with and without the
host's firewall. Each "refused" result has a control on the same path that
succeeds, so a refusal is attributable to the socket binding and not to
filtering — and the whole matrix, except the one row that needs a global IPv6
address, was repeated on OTP 27, 28 and 29 in a container with its own network
namespace (no host rules) to confirm it.

The point of the repository is that a reviewer — or anyone, later — does not
have to take the table on faith or rebuild the setup by hand. The analysis
also states what was *not* measured (a second physical host, Windows/macOS,
TLS distribution) and why, so the boundary of the evidence is explicit.

## Status

Open, DCO and CLA signed, mergeable, awaiting review. Whatever the maintainers decide,
the gap is now described publicly, with evidence that reproduces.

## References

- PR: <https://github.com/erlang/otp/pull/11617>
- Measurements: <https://github.com/erts-sched/otp-loopback-node-measurements>
- The originating case: [VS Code Erlang extension RCE](../vscode-erlang-loopback-rce/) · [GHSA-573p-mcvv-hchg](https://github.com/pgourlain/vscode_erlang/security/advisories/GHSA-573p-mcvv-hchg)
- Precedent: CVE-2022-24706 — Apache CouchDB
