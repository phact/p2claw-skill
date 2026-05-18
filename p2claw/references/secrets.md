---
name: secrets
description: |
  Secrets management for p2claw apps via fnox. The skill bundles
  `scripts/install-fnox.sh` and recommends `fnox exec --` for
  loading API keys, database URLs, and OAuth secrets into apps
  exposed over p2claw. Covers both the standard `p2claw apps expose`
  flow and integration points for `p2claw-run` (see
  `references/cloud-run-compat.md` for the Cloud-Run-specific
  patterns).
---

# Secrets for p2claw apps (via fnox)

p2claw doesn't manage secrets — the agent's job is `name → upstream`
routing. But anything you `expose` is on the public internet, so
the app behind it almost always needs secrets (API keys, database
credentials, OAuth client secrets, session signing keys, etc.) and
those secrets need to get into the process safely.

The skill's recommended local secrets layer is **[fnox](https://github.com/jdx/fnox)**:
a small CLI that stores secrets in pluggable backends (age, KMS,
keychain, password-store, …) and loads them into a child process on
demand via `fnox exec --`. The skill ships an installer for it.

---

## Install

```bash
bash scripts/install-fnox.sh
```

The installer is idempotent and picks the best path for the
platform (`mise → brew → cargo → prebuilt binary`). If `fnox` is
already on `$PATH` it exits with a green tick and does nothing.

The script refuses on native Windows (Git Bash / MSYS / Cygwin) —
fnox is POSIX-only; tell the user to run inside WSL, same as the
rest of the skill.

---

## Quick start

```bash
fnox init                                         # creates fnox.toml
fnox set DATABASE_URL "postgresql://localhost/mydb"
fnox set STRIPE_KEY "sk_test_..."

fnox exec -- ./bin/dev-server                     # secrets in child env
```

`fnox.toml` lives at the project root. Pick a backend that matches
the user's environment:

- **age / password-store / keychain** — solo dev on a laptop.
- **AWS / Azure / GCP KMS** — team or CI with cloud creds.
- **1Password / Bitwarden / KeePass** — devs already using a manager.

`fnox` documents the full provider list; the skill doesn't make a
recommendation beyond "match what the user already uses for other
secrets."

---

## With the standard `apps expose` flow

For apps the user starts themselves (`npm run dev`,
`python -m http.server`, a built binary), fnox sits in front of the
process. p2claw doesn't care:

```bash
# Terminal 1 — start the app with secrets injected
fnox exec -- npm run dev          # binds 127.0.0.1:5173 with $DATABASE_URL etc.

# Terminal 2 — expose it
p2claw apps expose --port 5173 myapp
```

The agent only sees `127.0.0.1:5173`; the secrets are in the dev
server's process env, never on p2claw's wire.

If the app reloads (HMR, nodemon, etc.) it keeps the env from the
parent `fnox exec` — no need to re-wrap for every restart.

---

## With docker (Cloud Run containers and similar)

See `references/cloud-run-compat.md` § *Secrets via fnox*. Short
version: `fnox exec --` wraps `docker run`, and the user names
which env vars to forward with `-e KEY` (no value — docker pulls
the value from the parent env where fnox put the secret).

---

## Security notes

- **fnox decrypts on demand.** Secrets are in plaintext only inside
  the wrapped command's process env. They're not written to
  `fnox.toml`, shell history, or `docker inspect` (assuming you
  pass them with `-e KEY=value` not literal values in the image).

- **p2claw is public.** Any secrets exposed via your app's response
  bodies (debug pages, error stacks, OpenAPI dumps, `/metrics`)
  leak the moment you `expose`. fnox keeps them out of *your* code's
  surface area; it can't protect them from your code's bugs.

- **Don't bake secrets into images.** For `p2claw-run`, never
  `ENV API_KEY=...` in a Dockerfile — that's baked into the image
  layer forever. Use `--set-env-vars` / `--env-vars-file` at run
  time, sourced from fnox.

- **OAuth client secrets are secrets too.** When the app does its
  own OAuth (Google Sign-In to call Google APIs as the user, etc.)
  the client secret should come from fnox, not `~/.env.local`. The
  redirect URI is *not* a secret (it's public by design) but needs
  to be added to the OAuth provider's allowlist separately.

- **If the goal is only "let the right people in,"** use the
  daemon's own auth gate instead of app-level OAuth — pass
  `--auth-oauth` to `p2claw apps expose` and the broker handles
  sign-in for you. The app then has no client secret to store and
  reads identity from `X-P2claw-*` headers. See
  `references/auth.md`.
