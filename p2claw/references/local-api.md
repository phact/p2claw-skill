---
name: local-api
description: |
  The p2claw agent's local HTTP API on a Unix socket (identity,
  status, sessions, routes, shares, private-app proxy, email) and
  the Python (`p2claw-agent-client`) and Node
  (`@p2claw/agent-client`) client libraries, with a minimal example
  of each.
---

# Local API and client libraries

Everything the `p2claw` CLI does to a running agent goes through a
small HTTP API on a Unix-domain socket. Programs on the machine (a
deploy script, an agent harness, an app that reads the inbox) can use
it directly instead of shelling out and parsing text.

- **Socket**: `agent.sock` in the agent's runtime directory:
  `$XDG_RUNTIME_DIR/p2claw/agent.sock` on Linux (typically
  `/run/user/<uid>/p2claw/agent.sock`), `/tmp/p2claw-<uid>/agent.sock`
  on macOS. `P2CLAW_AGENT_RUNTIME_DIR` overrides. The agent logs the
  path at start.
- **Auth**: Unix peer credentials. Connections from a different UID
  are refused; no tokens or headers. Local only, never on a TCP port.
- **Shape**: everything under `/v1/`, JSON responses, errors as
  non-2xx with `{"error": "...", "detail": "..."}`. The `http://localhost`
  host in curl examples is a placeholder.

```bash
SOCK="$XDG_RUNTIME_DIR/p2claw/agent.sock"
curl --unix-socket "$SOCK" http://localhost/v1/status
```

---

## Endpoints

| Endpoint | Does | CLI |
|---|---|---|
| `GET /v1/identity` | `{peer_id, alias, registered}` | `p2claw identity` |
| `GET /v1/status` | version, uptime, route count, `coord.state` (`connected` / `connecting` / `disconnected`) | `p2claw status` |
| `GET /v1/sessions` | active inbound connections: `kind` (`browser`, `iroh`), `transport` (`direct`, `relay`, `unknown`), age; no visitor IPs | `p2claw sessions` |
| `GET /v1/routes` | `{routes: [{name, upstream, url, auth, …}]}` | `p2claw apps list` |
| `GET /v1/routes/<name>` | one route, 404 if missing | `p2claw apps show` |
| `POST /v1/routes` | register or replace: `{"name","upstream":"http://127.0.0.1:3000"}`; add `"visibility":"private"` (then `"upstream":"unix:/path.sock"` is allowed); the gate is `"auth":[{"kind":"oauth","providers":["github"]}]` (omit `providers` for any). Returns `url` and `pending_announce` | `p2claw apps expose` |
| `DELETE /v1/routes/<name>` | remove | `p2claw apps unexpose` |
| `GET /v1/shares`, `PUT /v1/shares` | read or replace the whole share table `{shares: [{app, peers: [...]}]}` | `p2claw apps share / unshare / shares` |
| `ANY /v1/proxy/<peer>/<app>/<path>` | HTTP or WebSocket to a private app another machine shared; response streamed as-is; 404 if not shared, 502 if unreachable | `p2claw apps connect` |
| `GET /v1/email` | addresses, enabled, allowlist, unread count, rejection totals | `p2claw email` |
| `PUT /v1/email` | `{"enabled": true|false}` | `email enable / disable` |
| `PUT /v1/email/allowlist` | replace the allowlist | `email allow / disallow` |
| `GET /v1/email/messages` | list; `?unread=1`; `?watch=1` streams `{"id": ...}` lines | `email list / watch` |
| `GET /v1/email/messages/<id>` | one message with bodies and attachment list; `?format=raw` | `email show` |
| `GET /v1/email/messages/<id>/attachments/<aid>` | attachment bytes | `email attachment` |
| `POST /v1/email/messages/<id>/ack` | mark handled | `email ack` |
| `DELETE /v1/email/messages/<id>` | delete | `email rm` |
| `GET /v1/email/rejected` | totals and recent rejected senders | `email rejected` |
| `GET /v1/email/forwarding`; `POST`, `DELETE /v1/email/forwarding/<account>` | Gmail forwarding requests; approve / revoke | `email forwarding …` |

`status.coord.state` is the agent's own view of its control link, not
proof that the public URL is reachable end to end.

---

## Client libraries

Both wrap the API above, find the socket the way the agent does
(`socket_path` / `socketPath` to override), and raise/reject with
`AgentError` (`status`, `error`, `detail`) or `AgentNotRunning`.
Source, MIT: `libs/agent-client/python` and `libs/agent-client/ts` in
<https://github.com/phact/p2claw-agent>. Check PyPI / npm for the
package before assuming a registry install works; if it isn't
published yet, install from that source directory.

### Python: `p2claw-agent-client`

Standard library only; `websocket()` needs the `websockets` extra.

```sh
pip install p2claw-agent-client               # HTTP only
pip install 'p2claw-agent-client[websocket]'  # plus websocket()
```

```python
from p2claw_agent_client import AgentClient

agent = AgentClient()
print(agent.status()["alias"])

agent.expose("web", port=5173)
agent.expose("db-api", socket_path="/run/db-api.sock")   # socket upstreams are private
agent.share("db-api", ["<their peer id>"])

r = agent.fetch("<their alias>", "db-api", "/rows?limit=10")   # private app shared with us
print(r.status, r.json())

for m in agent.email_messages(unread=True):      # list of summaries; catch up first
    handle(agent.email_message(m["id"])); agent.email_ack(m["id"])
for id in agent.email_watch():                   # yields message ids as they arrive
    handle(agent.email_message(id)); agent.email_ack(id)
```

Methods: `identity() status() sessions() apps() app(name)
expose(name, port=|socket_path=|upstream=, private=, auth_oauth=)
set_auth(name, auth_oauth) unexpose(name) shares() share(app, peers)
unshare(app, peer=None) email() email_enable() email_disable()
email_allow(addrs) email_disallow(addr) email_messages(unread=False)
email_message(id, raw=False) email_attachment(id, aid) email_ack(id)
email_delete(id) email_watch() email_rejected()
fetch(peer, app, path, method=, headers=, body=|json_body=, stream=)
websocket(peer, app, path, headers=)`.

### Node: `@p2claw/agent-client`

Node 20+, no runtime dependencies; `websocket()` needs `ws`.

```sh
npm install @p2claw/agent-client
npm install ws      # only for websocket()
```

```ts
import { AgentClient } from "@p2claw/agent-client";

const agent = new AgentClient();
console.log((await agent.status()).alias);

await agent.expose("web", { port: 5173 });
await agent.expose("db-api", { socketPath: "/run/db-api.sock" });
await agent.share("db-api", ["<their peer id>"]);

const r = await agent.fetch("<their alias>", "db-api", "/rows?limit=10");
console.log(r.status, r.json());

for (const m of await agent.emailMessages({ unread: true })) {   // array of summaries
  await handle(await agent.emailMessage(m.id)); await agent.emailAck(m.id);
}
for await (const id of agent.emailWatch()) {                      // message ids as they arrive
  await handle(await agent.emailMessage(id)); await agent.emailAck(id);
}
```

Methods: `identity() status() sessions() apps() app(name)
expose(name, { port | socketPath | upstream, private, authOauth })
setAuth(name, authOauth) unexpose(name) shares() share(app, peers)
unshare(app, peer?) email() emailEnable() emailDisable()
emailAllow(addrs) emailDisallow(addr) emailMessages({ unread })
emailMessage(id, { raw }) emailAttachment(id, aid) emailAck(id)
emailDelete(id) emailWatch() emailRejected()
fetch(peer, app, path, { method, headers, body | json })
request(method, target, opts) proxyPath(peer, app, path)
websocket(peer, app, path, { headers })`.

`fetch` returns the app's response as-is, including error statuses;
an app that isn't shared answers 404 like one that doesn't exist.
