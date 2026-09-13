---
title: "ElixirLS: binding the MCP server to loopback"
---

# ElixirLS: binding the MCP server to loopback

*September 2026 — [elixir-lsp/elixir-ls](https://github.com/elixir-lsp/elixir-ls),
the Elixir language server. Hardening change proposed as
[elixir-lsp/elixir-ls#1275](https://github.com/elixir-lsp/elixir-ls/pull/1275).
Measurements: [erts-sched/elixir-ls-mcp-bind-measurements](https://github.com/erts-sched/elixir-ls-mcp-bind-measurements).
The same class as the [VS Code Erlang extension RCE](../vscode-erlang-loopback-rce/),
in a second BEAM tool, at a lower severity.*

## What it is

ElixirLS ships an optional MCP server so that an LLM client can ask the
language server about the open project: find a definition, read docs, list
implementations, resolve the environment at a location. It is a TCP server
inside the BEAM, and it called `:gen_tcp.listen/2` without an `{:ip, _}`
option, so it bound `0.0.0.0` — every interface — with no authentication.

The maintainer had already made the feature opt-in after a user raised the
network concern ([#1230](https://github.com/elixir-lsp/elixir-ls/issues/1230)):
that settled *whether* the server starts. Which interface it binds once started
was still open, and that is what the change settles.

## What it is not

Not a remote code execution and not an arbitrary-file read. I checked the
request handler before writing anything: the six tools are read-only project
inspection, and `get_environment` returns the semantic environment at a
location, not the file's bytes. What a network peer got, while MCP was enabled,
was information about the developer's open project. Severity low to medium;
mitigated further by the opt-in default. This is stated in the pull request in
those words, because inflating it would have been the fastest way to lose the
maintainer.

## How it was measured

Starting the server through the language server's own path on `master`, the
listening socket reported `{0,0,0,0}` and a client on the host's LAN address was
served a `tools/call` request. With the change, the socket reports
`{127,0,0,1}` and the same connection is refused. The exact listen options,
before and after, were then repeated in Docker bridge-network containers on
OTP 27, 28 and 29 — a network namespace of their own, so no host firewall
could be the cause — and the outputs are in the measurements repository.

The pull request carries a test that asserts the bound address: red on
`master` ({% raw %}`right: {:ok, {{0, 0, 0, 0}, ...}}`{% endraw %}), green with
the change.

## What the review caught

Before sending, the change went through an adversarial review, and it caught a
wrong statement of mine: I had justified changing the bundled client from
`localhost` to `127.0.0.1` with "on some systems `localhost` resolves to `::1`
and would no longer match". Measured, that was false on two counts — `0.0.0.0`
is not a dual-stack bind, so a `::1` client was already refused before the
change; and `:gen_tcp.connect/4` given a hostname resolves it in the IPv4
family by default, so the bundled bridge would have kept working either way.
The commit message and the PR say what is actually true. The review also found
that binding one address can fail where the wildcard bind cannot
(`:eaddrnotavail`), which would have taken the whole language server down — the
change now degrades to "MCP not running" instead — and that stopping the server
left an accept loop spinning, which the new test would have surfaced in CI.

## Status

Open, awaiting review; all four CI gates (compile with warnings as errors,
format, full test suite, dialyzer) run locally with the exact commands before
opening. The trade-off is stated in the PR: MCP is no longer reachable from
another host, and there is no setting to opt back in — with an offer to add
`elixirLS.mcpHost` if the maintainer prefers an escape hatch.

## References

- PR: <https://github.com/elixir-lsp/elixir-ls/pull/1275>
- Measurements: <https://github.com/erts-sched/elixir-ls-mcp-bind-measurements>
- The prior thread: <https://github.com/elixir-lsp/elixir-ls/issues/1230>
- The originating case: [VS Code Erlang extension RCE](../vscode-erlang-loopback-rce/)
- The upstream side: [documenting how to bind a distributed Erlang node to loopback](../otp-loopback-node-docs/)
