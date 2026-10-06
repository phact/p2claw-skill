---
name: auth
description: |
  Sign-in for p2claw apps through the p2claw OAuth broker. Three
  patterns: the broker as OIDC provider for apps with their own
  login (recommended when available), the `--auth-oauth` gate at
  the agent for apps without login, and partial gating with a 401
  from the app. Identity headers, header stripping, 401/503/501
  responses, CLI callers, and `apps set-auth / clear-auth`.
---

# Sign-in for p2claw apps

p2claw runs an OAuth broker at `https://oauth.p2claw.com`. It holds
the Google and GitHub registrations, so neither the user nor the app
registers an OAuth client with a provider. The broker is used in one
of three ways, and the choice depends on what the app already has.

| The app… | Use | Result |
|---|---|---|
| has an OIDC / OAuth login setting (Immich, Grafana, Nextcloud, Forgejo, …) | broker as **OIDC provider** | real per-user accounts inside the app |
| has no login of its own | **gate** at the agent (`--auth-oauth`) | nobody reaches the app without signing in; app reads headers if it cares |
| needs login on some paths only | **partial gating**: app returns 401 | public routes stay public; protected ones trigger sign-in |

Prefer the first whenever the app supports it. The gate is the
fallback for apps that have nothing.

---

## 1. Broker as the app's OIDC provider

Order matters: **expose first, configure second**. The broker only
accepts redirect URIs on the app's live p2claw host, so the app's OIDC
settings won't validate until the app is reachable at
`https://<app>-<alias>.p2claw.com/`.

```bash
p2claw apps expose immich --port 2283      # no --auth-oauth
p2claw identity                            # copy the peer id
```

Then in the app's OIDC / OAuth settings:

| Setting | Value |
|---|---|
| Issuer / discovery URL | `https://oauth.p2claw.com` |
| Client ID | this machine's peer id (from `p2claw identity`) |
| Client secret | leave empty |
| Token endpoint auth method | `none` (public client with PKCE) |
| Signing algorithm | `EdDSA` |
| Scopes | `openid email profile` |
| Redirect / callback URI | the app's default, on `https://<app>-<alias>.p2claw.com` |
| External / server URL (if the app has one) | `https://<app>-<alias>.p2claw.com` |

Why there is no secret: the client ID is the machine's public key,
and the broker only delivers logins to URLs that belong to that key.
Knowing the client ID lets nobody receive the app's logins.

Leave the agent-side gate **off** for these apps. The app runs its own
login page and sessions; adding `--auth-oauth` would force a second
sign-in and break non-browser clients (mobile apps, API tokens) the
app supports.

**Auto-register.** If the app offers "auto register" or "create
account on first login", anyone who can sign in to the broker with
Google or GitHub gets an account while it is on. Create accounts up
front, or enable it only while onboarding, then turn it off.

---

## 2. Gate at the agent (`--auth-oauth`)

```bash
p2claw apps expose <name> --port <port> --auth-oauth
p2claw apps expose <name> --port <port> --auth-oauth github,google
```

- No value: any provider the broker has configured.
- Comma-separated list, no spaces: only those providers.
- `--auth-oauth ""` is rejected. Unknown provider names are rejected
  at registration.
- Can't be combined with `--private`.

Flow: visitor opens the URL → no valid session → sign-in page listing
the allowed providers → OAuth with the chosen provider → broker mints a
session → back to the original URL → the agent validates the session
against the broker's signing keys and forwards the request with
identity headers. The app runs no OAuth code and sees no tokens.

### Identity headers the app receives

| Header | Present | Value |
|---|---|---|
| `X-P2claw-User` | always | stable user id at the provider |
| `X-P2claw-Email` | always | verified email |
| `X-P2claw-Provider` | always | `github`, `google`, … |
| `X-P2claw-Name` | when the provider has one | display name |
| `X-P2claw-Picture` | when the provider has one | avatar URL |

The agent **always strips** incoming `X-P2claw-*` headers before
forwarding, on every app, gated or not, and injects them only after
validating the session on this machine. If the header is present, it
was verified. Key users by `X-P2claw-User` + `X-P2claw-Provider`; the
same email can arrive from different providers.

```js
app.get("/", (req, res) => {
  res.send(`hello, ${req.headers["x-p2claw-name"] ?? req.headers["x-p2claw-email"]}`);
});
```

### Responses to callers without a session

All carry `P2claw-Auth-Required: true` so a client can branch on the
header without parsing the body:

- `401`: no or invalid session; browsers are sent to sign in
  automatically, CLI clients see the 401.
- `503`: the broker's signing keys are unreachable and the agent fails
  closed. Transient; retry.
- `501`: the app lists an auth method this agent build doesn't
  implement. Upgrade the agent on the machine that runs the app.

### Changing the gate on an existing app

```bash
p2claw apps show <name> [--json]                   # current auth list
p2claw apps set-auth <name> --auth-oauth github    # replace the list
p2claw apps set-auth <name>                        # no flag = clear
p2claw apps clear-auth <name>                      # back to public
```

`set-auth` replaces, so pass every provider wanted. Existing sessions
stay valid until they expire.

### CLI and non-browser callers of a gated app

The agent accepts the session either as the `__p2claw_session` cookie
or as `Authorization: Bearer <session token>`; both are stripped
before the request reaches the app. For unattended access (CI,
scheduled jobs) the gate is the wrong layer: leave the app public and
authenticate inside it, or make it private and share it with the
calling machine (`references/private-apps.md`).

---

## 3. Partial gating from inside the app

Leave the app public (no `--auth-oauth`). On a path that needs login,
if `X-P2claw-User` is missing, respond `401` with
`P2claw-Auth-Required: true`. The browser handles it exactly as it
does a gated app: sign-in, then back to the same path. From then on
the visitor's requests to **every** route on the app carry the
identity headers, because the agent injects identity on public apps
too whenever the request has a valid session.

```js
app.get("/admin", (req, res) => {
  if (!req.headers["x-p2claw-user"]) {
    return res.set("P2claw-Auth-Required", "true").sendStatus(401);
  }
  res.send(`welcome, ${req.headers["x-p2claw-email"]}`);
});
```

```python
@app.get("/admin")
def admin():
    if "X-P2claw-User" not in request.headers:
        return "", 401, {"P2claw-Auth-Required": "true"}
    return f"welcome, {request.headers['X-P2claw-Email']}"
```

On a public app the agent never fails a request on auth machinery: no
session, a bad session, or an unreachable broker all pass the request
through untouched (without identity headers).

---

## What the gate is not

- **Not authorization.** It answers "who is this" (and via which
  provider). Whether that person may do something is the app's
  decision, made from the headers.
- **Not a fix for an unsafe upstream.** A gated debug shell is still
  a debug shell for everyone with a Google account and the link.
- **Not app-level OAuth.** If the app needs a token to call Google or
  GitHub APIs *as the user*, it still runs its own OAuth flow and
  holds its own client secret (`references/secrets.md`).
- **Not a replacement for the app's own login.** If the app has
  sessions, a cookie login, or bearer tokens, those keep working
  unchanged over p2claw. The one visible difference: HTTP Basic auth
  shows p2claw's sign-in form instead of the browser's native dialog;
  the credentials still go to the app.

---

## When to suggest a gate

- Internal tools, dashboards, drafts, prototypes for a named
  reviewer; "only my team / only me / only my client".
- Anything from the SKILL.md security list that the user insists on
  exposing anyway: the gate narrows the audience from the internet to
  signed-in accounts; it does not remove the risk.
- Apps that talk to databases, cloud accounts, or LLMs with tools.
