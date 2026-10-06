---
name: private-apps
description: |
  Private apps between machines running the p2claw agent: expose
  with `--private` or `--socket`, share by peer id with `apps
  share / unshare / shares`, use a shared app with `apps connect`
  or the local API's `/v1/proxy` path, and read the caller from
  `X-P2claw-Peer`.
---

# Private apps between machines

Browsers reach a machine over WebRTC. Machines running the agent
reach each other over direct, end-to-end encrypted QUIC connections,
each side identified by its key. That is the path for **private
apps**: apps with no URL, reachable only by machines the owner shares
them with. Use it for anything that should never face a browser (a
database API, a build cache, an agent's tool server) but that another
machine needs.

A share names the other machine by its **peer id**, the public key
`p2claw identity` prints there. It can be one of the user's own
machines or someone else's.

---

## Expose a private app

```bash
p2claw apps expose db --port 8080 --private
p2claw apps expose db --socket /run/user/1000/db.sock   # implies --private
```

- Private apps are never announced to coordination, so their names
  never leave the machine. No public URL, no home-page entry, no
  quota use.
- `--socket` upstreams are only allowed for private apps.
- Re-exposing without `--private` or `--public` keeps the current
  visibility, so a private app can't go public by accident. Pass
  `--public` explicitly to flip it.
- `--private` can't be combined with `--auth-oauth`; the share table
  is the access control.

---

## Share it

On the machine that runs the app:

```bash
p2claw apps share db --with <peer id>          # repeat --with for several
p2claw apps shares [--json]                    # what is shared with whom
p2claw apps unshare db --with <peer id>        # one peer
p2claw apps unshare db                         # every peer
```

Nothing is shared by default. Shares live only on this machine;
coordination cannot grant access. Unsharing applies to the peer's
next request; an open WebSocket or streaming response runs until it
closes on its own (restart the agent to cut those).

---

## Use an app shared with you

On the other machine, `apps connect` serves the shared app on a local
port and runs in the foreground until Ctrl-C:

```bash
p2claw apps connect <alias or peer id>/db --listen 127.0.0.1:9000
```

```
connected db on <alias>
  http://127.0.0.1:9000/
  (Ctrl-C to stop)
```

Default `--listen` is `127.0.0.1:0` (a free port, printed). Point
anything that speaks HTTP or WebSocket at that address. Run it in the
background (`&`, or a service unit) when a long-lived program depends
on it.

Programs can skip `apps connect` and call the local API directly:
`ANY /v1/proxy/<peer>/<app>/<path>` on the agent's socket forwards
HTTP and WebSocket traffic to the shared app and streams the response
back.

```bash
curl --unix-socket "$XDG_RUNTIME_DIR/p2claw/agent.sock" \
  "http://localhost/v1/proxy/<alias>/db/rows?limit=10"
```

The Python and Node clients wrap this as `fetch(peer, app, path)` and
`websocket(peer, app, path)`; see `references/local-api.md`.

Responses: the app's own status codes come back as-is. An app that
isn't shared with you answers `404`, the same as one that doesn't
exist, so names can't be probed. `502` means the other machine
couldn't be found or reached.

Don't try a `*.p2claw.com` hostname for a private app. It doesn't
resolve, and the lookup would send the name to coordination.

---

## Who is calling

Every request to a private app carries `X-P2claw-Peer` with the
caller's peer id. The agent strips any `X-P2claw-*` headers the caller
sent and sets this one itself after checking the share, so the app can
trust it and use it for per-machine authorization.

---

## Patterns

- **Agent tool server on machine A, agent on machine B**: expose the
  tool server `--private` on A, share with B's peer id, on B run
  `apps connect A-alias/tools --listen 127.0.0.1:7000` and point the
  agent at `http://127.0.0.1:7000`.
- **Database or internal API shared with a collaborator**: they send
  their `p2claw identity` peer id; you `apps share`. Revoke with
  `apps unshare`.
- **Both public and private faces**: two apps on the same upstream
  port, one public (optionally gated), one `--private` under another
  name.
