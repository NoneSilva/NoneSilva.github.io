---
title: "VS Code Erlang extension: finding and fixing an unauthenticated RCE"
---

# VS Code Erlang extension: finding and fixing an unauthenticated RCE

*September 2026 — [pgourlain/vscode_erlang](https://github.com/pgourlain/vscode_erlang), the Erlang extension for VS Code. Reported as [#328](https://github.com/pgourlain/vscode_erlang/issues/328), fixed in [#329](https://github.com/pgourlain/vscode_erlang/pull/329) and [#330](https://github.com/pgourlain/vscode_erlang/pull/330), published as [GHSA-573p-mcvv-hchg](https://github.com/pgourlain/vscode_erlang/security/advisories/GHSA-573p-mcvv-hchg) (severity High), released in 1.1.5.*

## What it is

The extension's local servers listened on every network interface instead of loopback. Its debugger command channel evaluates whatever it receives with `erl_eval`, with no authentication, so anyone able to reach the developer's machine on those ports could run arbitrary Erlang — and therefore arbitrary OS commands — as the developer. A second, opt-in path (Erlang distribution with a predictable cookie) gave the same result through the classic BEAM route. Both are fixed in 1.1.5 by binding everything to `127.0.0.1`. The extension has ~213,000 installs on the VS Code Marketplace (September 2026).

## Discovery

With the extension running on an Erlang project, `ss -tlnp` showed two `beam.smp` listeners on all interfaces:

```
LISTEN 0 5 0.0.0.0:43117 0.0.0.0:* users:(("beam.smp",...))
LISTEN 0 5 0.0.0.0:46653 0.0.0.0:* users:(("beam.smp",...))
```

The cause was a missing `{ip, ...}` option in both `gen_tcp:listen` calls:

- `apps/erlangbridge/src/gen_lsp_sup.erl` — the LSP server:
  `-define(TCP_OPTIONS, [binary, {packet, raw}, {active, once}, {reuseaddr, true}]).`
- `apps/erlangbridge/src/gen_connection.erl` — the debugger command server:
  `-define(TCP_OPTIONS, [binary, {active, false}]).`

Without `{ip, _}`, OTP binds `0.0.0.0`. Reaching the debugger port is code execution because `vscode_connection.erl` routes the `debugger_eval` verb straight into `erl_scan:string/1` → `erl_parse:parse_exprs/1` → `erl_eval:exprs/2`, unauthenticated. `os:cmd/1` is one expression away.

While preparing the fix, two more all-interfaces listeners turned up on the Node side (`lib/ErlangAdapterDescriptorFactory.ts` and the free-port probe in `lib/lsp/lspclientextension.ts`), and the LSP client resolved `localhost` rather than pinning `127.0.0.1`.

## How it was measured

Claims about bind addresses are cheap; measurements are not. I started the Erlang side exactly as the extension does, inside a Linux container with a LAN address of `172.17.0.2`, and probed each listener from that address and from loopback with `nc -zv`.

Before (master):

```
LISTEN 0 5 0.0.0.0:9000    users:(("beam.smp",pid=7,fd=17))
LISTEN 0 5 0.0.0.0:53459   users:(("beam.smp",pid=83,fd=17))
Connection to 172.17.0.2 9000 port [tcp/*] succeeded!
Connection to 172.17.0.2 53459 port [tcp/*] succeeded!
```

After (fix):

```
LISTEN 0 5 127.0.0.1:9000  users:(("beam.smp",pid=7,fd=17))
LISTEN 0 5 127.0.0.1:35661 users:(("beam.smp",pid=77,fd=17))
nc: connect to 172.17.0.2 port 9000 (tcp) failed: Connection refused
nc: connect to 172.17.0.2 port 35661 (tcp) failed: Connection refused
Connection to 127.0.0.1 9000 port [tcp/*] succeeded!
Connection to 127.0.0.1 35661 port [tcp/*] succeeded!
```

The LAN address is refused; the legitimate client on loopback still connects.

## The fix (#329)

Four one-line changes and a client pin:

```erlang
%% gen_lsp_sup.erl
-define(TCP_OPTIONS, [binary, {packet, raw}, {active, once}, {reuseaddr, true}, {ip, {127,0,0,1}}]).
%% gen_connection.erl
-define(TCP_OPTIONS, [binary, {active, false}, {ip, {127,0,0,1}}]).
```

```ts
// ErlangAdapterDescriptorFactory.ts, lspclientextension.ts
}).listen(0, '127.0.0.1');
server.listen(0, '127.0.0.1', ...);
var host = options.host || '127.0.0.1';
```

`{ip, Addr}` does not *add* an interface: a TCP socket binds exactly one local address, and this replaces the default `0.0.0.0` with loopback. In `listen(0, host)` the `0` is the port — ephemeral, chosen by the OS — not an interface. Worth stating, because it is easy to misread.

This is safe for every supported setup: both Node clients already connected over loopback, the Erlang listeners were already IPv4-only, and under VS Code Remote the extension host and the BEAM run on the same machine.

## The distribution path (#330)

With `erlang.erlangDistributedNode` enabled (off by default), the LSP node was started with `-sname vscode_<port> -setcookie vscode_<port>`. That is the textbook BEAM compromise: epmd (4369) answers name queries from the network, the node name reveals the port, the cookie *is* the port, so `net_adm:ping` → `rpc:call(Node, os, cmd, [...])`. Same class as CVE-2022-24706 (Apache CouchDB).

The obvious fix — `-kernel inet_dist_use_interface {127,0,0,1}` — has a trap I only found by measuring:

| Configuration | Remote (LAN) | Local remsh |
|---|---|---|
| A. `-sname` (master) | reachable | pong |
| B. `-sname` + `inet_dist_use_interface {127,0,0,1}` | refused | **pang** |
| C. `-name vscode_<port>@127.0.0.1` + `inet_dist_use_interface` | refused | pong |
| D. `-name …@127.0.0.1` alone | **reachable** | pong |

B closes the network hole but silently breaks the feature: a short name resolves to the host's LAN address, which the loopback-bound listener refuses. D shows that the node name alone binds nothing. Only C keeps remsh working *and* closes the network. `ERL_EPMD_ADDRESS=127.0.0.1` additionally stops epmd from enumerating the node off-host.

One more trap: the extension spawns `erl` with `shell: true`. Under bash, a bare `{127,0,0,1}` brace-expands to `127 0 0 1`; under dash it does not. Double quotes protect it in both, so the argument is passed as `"{127,0,0,1}"`.

I also tried starting distribution from inside the BEAM (`net_kernel:start/1` after `application:set_env`) to avoid the shell entirely. It is not a drop-in: a dynamically started `net_kernel` does not auto-start epmd (`register/listen error: econnrefused`), and `erlang:set_cookie/2` fails on a node that never came up. The command-line approach stayed.

## Proving no regression

Every change shipped with a fence that is red on master and green with the fix:

- `gen_lsp_sup_SUITE` and `gen_connection_SUITE` (Common Test) assert that `inet:sockname/1` of each listen socket is `{127,0,0,1}`; `gen_connection_SUITE` also checks that a loopback client still connects. On master both fail with `{0,0,0,0}`.
- `test/test-suite/erlangShellLSP.test.ts` (mocha) asserts the distributed-node arguments: `-name …@127.0.0.1`, no `-sname`, `inet_dist_use_interface`, `ERL_EPMD_ADDRESS`.
- The maintainer's CI mirrored in a container: `./rebar3 ct` green on OTP 25 (the CI version) and OTP 27; `npm test` — which starts a real VS Code and talks to the LSP server over its socket — green as well.
- `dialyzer`: identical output before and after — the repository's pre-existing warnings, none added.

## Disclosure

| Date (UTC) | Event |
|---|---|
| 2026-09-02 00:25 | Issue #328 opened with the `ss` evidence, exact lines and a two-line fix |
| 2026-09-02 06:22 | Maintainer: "send me a PR" |
| 2026-09-05 | PRs #329 and #330 opened |
| 2026-09-06 05:55 | Both merged; #328 closed |
| 2026-09-06 07:40 | GHSA-573p-mcvv-hchg published (High); 1.1.5 released |

Pierrick Gourlain merged both PRs in a single review pass and published the advisory and the release within two hours of merging — an exemplary response. The advisory credits this work as reporter.

Weakness classes: CWE-1327 (binding to an unrestricted IP address), CWE-306 (missing authentication for a critical function), CWE-95 (eval injection), CWE-1391 (weak credentials).

## What is not fixed

Loopback binding removes the network exposure; it is not authentication. Processes on the same host can still reach the command channel. That is a design decision for the maintainer, and it is stated in the PRs.

## References

- Issue: <https://github.com/pgourlain/vscode_erlang/issues/328>
- Fixes: <https://github.com/pgourlain/vscode_erlang/pull/329> · <https://github.com/pgourlain/vscode_erlang/pull/330>
- Advisory: <https://github.com/pgourlain/vscode_erlang/security/advisories/GHSA-573p-mcvv-hchg>
- Release notes: <https://github.com/pgourlain/vscode_erlang/blob/master/CHANGELOG.md>
- Marketplace: <https://marketplace.visualstudio.com/items?itemName=pgourlain.erlang>
- Precedent: CVE-2022-24706 — Apache CouchDB, Erlang distribution reachable with a default cookie
