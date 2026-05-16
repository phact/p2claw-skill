---
name: cloud-run-compat
description: |
  Optional Cloud-Run-compatible deploy mode for the p2claw skill.
  The `p2claw-run` CLI mirrors `gcloud run deploy` flags so existing
  Cloud Run containers can run locally over p2claw unchanged. The
  pitch: swap the binary name, keep the command.
---

# Cloud Run compatibility (`p2claw-run`)

`p2claw-run` is a side feature shipped with the p2claw skill. It
wraps `docker` + `p2claw expose` behind a CLI that accepts the same
flags as `gcloud run deploy`, so a container built for Cloud Run
runs locally with no code changes and no new mental model.

The pitch is one line: **rename the binary, keep the command.**

```bash
gcloud run deploy myapp --image gcr.io/proj/myapp --region us-east1 --allow-unauthenticated
# becomes
p2claw-run deploy myapp --image gcr.io/proj/myapp --region us-east1 --allow-unauthenticated
```

Both produce a working URL serving the same content. The flags that
don't translate locally (`--region`, `--allow-unauthenticated`,
`--platform`) are accepted and ignored — they exist so muscle
memory works, not because they do anything.

---

## When to use this vs. the regular skill flow

The default skill flow (`p2claw expose <name> <port>`) is the right
choice for almost everything: a dev server you already started, a
static directory, a `python -m http.server`, etc. It assumes you
control how the process gets started.

`p2claw-run` is the right choice when:

- You already have a Cloud Run container (or a Dockerfile / source
  directory that builds one) and want to run it locally without
  rewriting the deploy step.
- You want `gcloud run deploy`-style ergonomics: an image reference,
  a service name, `$PORT` injection, env-var flags.
- The container is already designed to the Cloud Run contract
  (stateless, listens on `$PORT`, fast start). If it isn't, fix
  that before reaching for this mode.

If you're not deploying a container, use the regular skill flow.

---

## The container contract

`p2claw-run` honors the parts of the Cloud Run contract that make
sense locally:

| Cloud Run guarantee | `p2claw-run` behavior |
|---|---|
| Container receives `$PORT` env var | Set to `--port` value (default 8080) |
| Inbound traffic only to `$PORT` | Only the mapped container port is reachable |
| Stateless | Container is run with `--rm` semantics; local-only labels track ownership |
| Public HTTPS URL | Yes — via p2claw's edge / WebRTC, same as `p2claw expose` |
| `--allow-unauthenticated` controls public access | **No-op locally — p2claw URLs are public by default** |

If your container expects to bind a hard-coded port instead of
reading `$PORT`, pass `--port <that-port>` so `p2claw-run` maps
correctly and still sets `$PORT` for hygiene.

---

## Flag reference

### Build / image

| `gcloud run deploy` | `p2claw-run deploy` | Notes |
|---|---|---|
| `--image IMAGE` | `--image IMAGE` | Pulled and run as-is. |
| `--source PATH` | `--source PATH` | Builds a local image. Uses `Dockerfile` if present, else falls back to Buildpacks via the `pack` CLI. |

### Runtime

| `gcloud run deploy` | `p2claw-run deploy` | Notes |
|---|---|---|
| `--port PORT` | `--port PORT` | Default 8080. Injected as `$PORT` and used as the container's listen port. |
| `--set-env-vars K=V,...` | `--set-env-vars K=V,...` | Comma-separated. Forwarded as `-e K=V` to docker. |
| `--env-vars-file FILE` | `--env-vars-file FILE` | **Divergence:** Cloud Run expects YAML; `p2claw-run` expects docker env-file syntax (`KEY=value` per line). Use whichever format your local docker workflow already uses. |

### No-ops (accepted for muscle memory, ignored)

| Flag | Why no-op |
|---|---|
| `--region` | There's one region: your laptop. |
| `--allow-unauthenticated` | p2claw URLs are always public. The flag's local moral equivalent is "I understand this is on the public internet" — see the security section in the main SKILL.md. |
| `--platform` | Managed vs. Anthos vs. GKE doesn't apply here. |

If a flag isn't listed above, `p2claw-run deploy` will reject it
rather than silently ignore it.

---

## What this doesn't replicate

`p2claw-run` is a local-dev convenience, not a Cloud Run replacement.
The following are **not** simulated:

- **Autoscaling.** One container, one instance. No concurrency
  governor, no cold-start replay, no min/max instances. If you need
  to test scaling behavior, use Cloud Run.
- **IAM / service accounts.** No identity is injected; the container
  has whatever local credentials happen to be in env vars.
- **Custom domains / domain mappings.** You get the p2claw URL
  (`https://app-<alias>.p2claw.com/`) and nothing else.
- **Secret Manager.** No automatic secret injection. Pass secrets as
  env vars yourself.
- **VPC connectors / Cloud SQL Auth Proxy.** Local networking only.
- **Cloud Run timeouts > 60 minutes.** No request-timeout enforcement
  at all in this mode — it's whatever the container does.
- **Traffic splitting / revisions.** `p2claw-run deploy NAME` replaces
  any container running under that name; no rollback target is kept.

If your test plan exercises any of the above, run on actual Cloud
Run, not here.

---

## Worked example

You have a Cloud Run service `myapp` deployed against
`gcr.io/proj/myapp`. To run it locally with the same surface area:

```bash
p2claw-run deploy myapp \
  --image gcr.io/proj/myapp \
  --region us-east1 \
  --allow-unauthenticated
```

What happens:

1. `--region` and `--allow-unauthenticated` are accepted and ignored.
2. A free localhost port is picked (say 49213).
3. The image is run as `docker run -d ... -p 127.0.0.1:49213:8080 -e PORT=8080 gcr.io/proj/myapp`.
4. `p2claw-run` polls `http://127.0.0.1:49213/` until the container responds.
5. `p2claw expose myapp 49213` registers the route.
6. You get `https://myapp-<your-alias>.p2claw.com/`.

Anyone with the URL hits your laptop. Same security caveats as the
regular skill flow: see "Security" in `SKILL.md`.

### Building from source

```bash
p2claw-run deploy myapp --source ./
```

- If `./Dockerfile` exists, runs `docker build`.
- Else, falls back to Buildpacks: `pack build` against
  `gcr.io/buildpacks/builder:latest`. Requires the `pack` CLI;
  install it or commit a Dockerfile.

### Env vars

```bash
p2claw-run deploy myapp \
  --image gcr.io/proj/myapp \
  --set-env-vars DATABASE_URL=postgres://...,LOG_LEVEL=debug

# or
p2claw-run deploy myapp --image gcr.io/proj/myapp --env-vars-file ./prod.env
```

`--env-vars-file` expects docker env-file syntax (one `KEY=value`
per line), not Cloud Run's YAML.

---

## Subcommands

```bash
p2claw-run services list                  # all p2claw-run services
p2claw-run services describe NAME         # `docker inspect` for one
p2claw-run services delete NAME           # stop container + remove route
```

`services list` shows `NAME / IMAGE / STATUS / UPSTREAM` for every
container labeled by `p2claw-run`. Containers started by raw
`docker run` aren't included.

---

## Implementation surface (what `p2claw-run` actually does)

For people debugging it:

- Container name: `p2claw-run-<service-name>`.
- Labels on the container: `p2claw-run=true`,
  `p2claw-run.service=<name>`, `p2claw-run.host-port=<port>`,
  `p2claw-run.container-port=<port>`, `p2claw-run.image=<image>`.
- Built source image tag: `p2claw-run/<service-name>:latest`.
- Health probe: any HTTP response from `http://127.0.0.1:<host-port>/`
  counts as healthy. 404 is fine. 60 s budget.
- Route registration: `p2claw expose <name> <host-port> --json --no-qr`,
  with a fallback to the human form if JSON parsing fails.
- Redeploys replace the existing container atomically (`docker rm -f`
  before `docker run`).

No state file, no background daemon — `docker ps --filter
label=p2claw-run=true` is the source of truth.

---

## Dependencies

- `docker` — required for everything.
- `p2claw` — required for `deploy`'s registration step.
- `python3` — required for free-port allocation and JSON parsing.
- `curl` — required for the health probe.
- `pack` — only required for `--source` without a Dockerfile.

If `--source` doesn't build a Dockerfile and `pack` is missing,
`p2claw-run` exits with a clear error pointing at either path.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `error: agent is not running` from `expose` | p2claw daemon's not up | `p2claw service install` or `p2claw run` (see SKILL.md §"Starting the daemon") |
| Container exits immediately during deploy | App crashed at startup | `p2claw-run` will surface the last 20 log lines and exit. Fix the app, retry. |
| `upstream did not respond within 60 s` warning | Slow boot, or app doesn't listen on `$PORT` | The route registers anyway. Check `docker logs p2claw-run-<name>`. |
| 502 from the public URL | Container is up but not serving | `curl http://127.0.0.1:<port>/` to confirm. If that works, retry — coord may be reconnecting. |
| `--set-env-vars` value contains a comma | Comma is the delimiter | Use `--env-vars-file` instead. |
| `services list` is empty after deploy | Container exited and was removed | `docker ps -a` to see exited containers; they self-cleaned. Redeploy. |
