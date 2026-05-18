---
name: auth
description: |
  Per-app sign-in gate via the daemon's OAuth broker. Covers the
  `--auth-oauth` flag on `p2claw apps expose`, the X-P2claw-*
  identity headers the daemon injects on authenticated requests,
  defense-in-depth header stripping, the 401/503 +
  P2claw-Auth-Required affordance for CLI clients, and the
  `apps show / set-auth / clear-auth` management surface.
---

# Auth gate (`--auth-oauth`)

p2claw URLs are public by default. The daemon ships an
**identity-aware proxy** in front of each exposed route: when an
app is registered with `--auth-oauth`, every inbound request is
gated on a valid session from p2claw's broker before reaching the
upstream. The verified identity is passed to the upstream in
trusted headers.

This is the right tool when the user wants "let only signed-in
people see this." It is **not** an app-level OAuth replacement — if
the app itself needs Google Sign-In / Auth0 / etc. for product
reasons (linking accounts, calling Google APIs as the user), the
app keeps doing that. The gate is a layer in front.

---

## The flag

```bash
p2claw apps expose --port <PORT> <NAME> --auth-oauth [<PROVIDERS>]
```

- `--auth-oauth` with **no value** → any provider the broker has
  configured is accepted.
- `--auth-oauth github,google` → restrict to the listed providers
  (comma-separated, no spaces).
- Empty list is rejected — omit the value to mean "all configured."
- Providers are validated coord-side at register time; an unknown
  name fails the expose with a clear error.

To register a public route, omit `--auth-oauth` entirely. The flag
is per-app, persisted in the daemon's `routes.json`, and announced
to coord on the next `route_announce`.

---

## How visitors authenticate

1. Visitor opens `https://<name>-<alias>.p2claw.com/`.
2. The daemon's middleware checks for a valid session JWT.
3. If absent or invalid → redirected to the broker's sign-in page,
   which lists the providers allowed for this route.
4. After the OAuth round-trip with the chosen provider, the broker
   mints a session JWT and sends the visitor back to the original
   URL.
5. The daemon validates the JWT (JWKS pulled from the broker) and
   forwards the request to the upstream with the identity headers.

The OAuth dance is entirely outside the upstream's process — the
user's app doesn't run any OAuth code, doesn't see any tokens,
doesn't need any client IDs or secrets. The app only ever sees
already-authenticated requests with the headers below.

---

## What the app sees on authenticated requests

| Header | Always? | Source |
|---|---|---|
| `X-P2claw-User` | yes | upstream `sub` claim (provider-stable user id) |
| `X-P2claw-Email` | yes | upstream `email` claim |
| `X-P2claw-Provider` | yes | issuer name (`github`, `google`, …) |
| `X-P2claw-Name` | conditional | upstream display name, if provided |
| `X-P2claw-Picture` | conditional | upstream avatar URL, if provided |

**Defense-in-depth:** incoming `X-P2claw-*` headers from visitors are
**always stripped** before forwarding, regardless of whether auth
is on. Apps can trust the headers they receive — there is no path
for a caller to spoof an identity by setting the header themselves.

Apps should treat `X-P2claw-User` + `X-P2claw-Provider` as the
identity key (the same email can come from different providers and
should not be merged silently).

---

## What unauthenticated callers see

The daemon responds with:

- `401 P2claw-Auth-Required: true` — visitor has no session, needs
  to sign in.
- `503 P2claw-Auth-Required: true` — broker's JWKS is unreachable;
  the daemon fails closed. Transient.

The `P2claw-Auth-Required: true` response header is stable across
both cases. CLI clients, webhook senders, and agents calling
p2claw-exposed APIs can branch on the header to drive
re-authentication or retry logic without having to parse the
response body.

Browsers don't need any of this — they get redirected to the broker
sign-in flow and back, transparently.

---

## Flipping auth on or off after expose

```bash
p2claw apps show <name>                            # current state (+ --json)
p2claw apps set-auth <name> --auth-oauth github    # change methods in place
p2claw apps set-auth <name>                        # clear (same as clear-auth)
p2claw apps clear-auth <name>                      # explicit clear, route goes public
```

`set-auth` replaces the method list — pass every provider you want,
not a delta. `apps show --json` gives the current `auth` array
suitable for scripting.

The daemon persists the change immediately and re-announces to
coord. Existing sessions stay valid until they expire; the change
only affects subsequent unauthenticated visitors.

---

## When to suggest the gate

Reach for `--auth-oauth` when **any** of these apply:

- The app exposes data that's only meant for specific people
  (internal tools, dashboards, draft work, prototypes shown to a
  named reviewer).
- The user says "I want only my team / only myself / only my client
  to see this."
- The upstream is a dev server with debug mode, hot-reload, source
  maps, a `/__debug__`-style route, or anything else in the
  SKILL.md §Security "not safe to expose" list. The gate doesn't
  fix the underlying risk, but it narrows the attacker pool from
  "the public internet" to "people who have an OAuth account at one
  of the allowed providers and the URL."
- The user is about to expose something that talks to a database,
  cloud account, or LLM-with-tool-use. Even a gated audience is
  better than a public one for these.

It is **not** a substitute for fixing dev-mode dangers — a gated
debug shell is still a debug shell available to anyone in the
allowed-provider set. Layer with care.

---

## What the gate isn't

- **Not authorization.** The gate decides "is this person
  authenticated" (and via which provider). It does **not** decide
  "is this person allowed to read this resource." That's the app's
  job — read `X-P2claw-User` / `X-P2claw-Email` and enforce.
- **Not app-level OAuth.** If the app needs an OAuth token to call
  Google APIs / GitHub APIs / etc. *as the user*, the app still
  runs its own OAuth flow. See `references/secrets.md` for storing
  the resulting client secret via fnox.
- **Not a tunnel ACL.** This is HTTP-layer auth on top of the
  public peer-HTTP transport. The URL itself is still
  enumerable / shareable; what auth does is make it useless to
  someone who isn't signed in.

---

## Reading the headers (sketch)

Express / Node:

```js
app.use((req, res, next) => {
  const user = req.get('x-p2claw-user');
  if (!user) return res.status(401).end();
  req.identity = {
    id:       user,
    email:    req.get('x-p2claw-email'),
    provider: req.get('x-p2claw-provider'),
    name:     req.get('x-p2claw-name')    || null,
    picture:  req.get('x-p2claw-picture') || null,
  };
  next();
});
```

Flask:

```python
from flask import request, abort

def identity():
    user = request.headers.get('X-P2claw-User')
    if not user:
        abort(401)
    return {
        'id':       user,
        'email':    request.headers['X-P2claw-Email'],
        'provider': request.headers['X-P2claw-Provider'],
        'name':     request.headers.get('X-P2claw-Name'),
        'picture':  request.headers.get('X-P2claw-Picture'),
    }
```

Both assume `--auth-oauth` is in effect for the route. With auth
off, the headers are absent and you fall back to anonymous handling.

---

## CLI / agent callers

For non-browser callers of a gated route, the broker can't run an
interactive OAuth dance. Two patterns:

1. **Re-auth in browser first**, get a session, then reuse the
   session cookie / bearer in CLI calls. The broker exposes a
   user-managed long-lived token for this pattern (see the broker's
   own docs; outside the daemon CLI's surface).
2. **Branch on `P2claw-Auth-Required: true`** in the response
   header. If present, the client knows to prompt the user to
   reauthenticate via a browser flow rather than retry the same
   request.

If a CLI workflow requires unattended access (CI, scheduled jobs),
the gate is the wrong layer — leave the route public and put auth
inside the app, or scope a separate route without the gate for that
client.
