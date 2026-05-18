---
name: cloud-run-compat
description: |
  Translation guide for running Cloud Run containers locally over
  p2claw. When the user has a Cloud Run image or a `gcloud run
  deploy ...` invocation, compose `docker run` + `p2claw apps expose`
  per the mapping below.
---

# Cloud Run containers, locally, over p2claw

When the user has an existing Cloud Run service (or a Dockerfile
they'd otherwise `gcloud run deploy --source` with), the local
equivalent is two primitives already covered elsewhere in the
skill:

```bash
docker run -d --rm --name <name> \
  -p 127.0.0.1:<host_port>:<container_port> \
  -e PORT=<container_port> \
  <image>
p2claw apps expose --port <host_port> <name>
```

The rest of this doc is mapping `gcloud run deploy` flags onto
those primitives. No new binary, no new mental model — just a
translation table the agent applies before running the commands.

---

## The container contract

The Cloud Run image expects to be invoked a specific way. The agent
honors the parts that make sense locally:

- **`$PORT` env** — the container reads it to know which port to
  listen on. Default 8080. Pass `-e PORT=<port>` and map the same
  `<port>` as the container side of `-p 127.0.0.1:<host>:<port>`.
- **HTTP, not HTTPS** — TLS terminates at p2claw's edge, not in the
  container.
- **Stateless** — `--rm` is fine; no local volumes by default.
- **`0.0.0.0` bind inside the container** — required for `-p` to
  reach it. Cloud Run images already do this.

`<host_port>` and `<container_port>` are usually different.
`<host_port>` is picked free (see the worked example); `<container_port>`
comes from `$PORT` (default 8080).

---

## Flag mapping

| `gcloud run deploy` flag | Local equivalent | Notes |
|---|---|---|
| `--image IMAGE` | `docker run ... IMAGE` | Pull + run as-is. |
| `--source PATH` | `docker build -t <tag> PATH && docker run ... <tag>` | If `PATH` has no Dockerfile, fall back to `pack build` (Buildpacks CLI). |
| `--port PORT` | `-e PORT=<port> -p 127.0.0.1:<host>:<port>` | Default 8080. |
| `--set-env-vars K=V,...` | `-e K=V` per pair | Comma-split. |
| `--update-env-vars K=V,...` | Same — re-run `docker run` | No live update; redeploy. |
| `--env-vars-file FILE` | `--env-file FILE` | docker uses `KEY=value` per line; Cloud Run wants YAML. If the user's file is YAML, either convert it or set each var with `-e`. |
| `--set-secrets KEY=secret:v` | See *Secrets via fnox* below | No local Secret Manager. |
| `--region` | (drop) | Local. |
| `--allow-unauthenticated` | (drop) | p2claw URLs are public by default. For "let only signed-in people in" (the local moral equivalent of Cloud Run IAP / `--no-allow-unauthenticated` + IAM), add `--auth-oauth` to the `p2claw apps expose` call — see `references/auth.md`. |
| `--platform` | (drop) | Managed / Anthos / GKE don't apply locally. |
| `--service-account` | (drop) | No GCP identity injected. If the app needs ADC, the user has to set `GOOGLE_APPLICATION_CREDENTIALS` themselves. |
| `--cpu`, `--memory` | (drop) | Container gets whatever docker gives it. |
| `--concurrency`, `--min-instances`, `--max-instances` | (drop) | Single container; no autoscaling. |
| `--timeout` | (drop) | Not enforced locally. |
| `--vpc-connector`, `--vpc-egress` | (drop) | Local networking. |

If a flag isn't on this list, ask the user before assuming it has
no local analog.

---

## What doesn't translate

- **Autoscaling** — one container, one instance, no concurrency
  governor, no cold-start replay.
- **IAM / service accounts** — no GCP identity is injected.
- **Custom domains / domain mappings** — URL is
  `https://<name>-<your-alias>.p2claw.com/`.
- **Secret Manager** — use fnox; see below.
- **VPC connectors / Cloud SQL Auth Proxy** — local networking only.
- **Request timeouts > 60 min** — no enforcement at all.
- **Traffic splitting / revisions** — no rollback target kept.

If the user's test plan exercises any of these, point them at
actual Cloud Run instead.

---

## Secrets via fnox

Cloud Run pulls secrets from Secret Manager via `--set-secrets` /
`--update-secrets`. The local equivalent is
**[fnox](https://github.com/jdx/fnox)** — see
`references/secrets.md` for general setup. Install with:

```bash
bash scripts/install-fnox.sh
```

Wrap the docker run with `fnox exec --` and forward the secrets
into the container by name:

```bash
fnox exec -- docker run -d --rm --name myapp \
  -p "127.0.0.1:${HOST_PORT}:8080" \
  -e PORT=8080 \
  -e DATABASE_URL -e STRIPE_KEY \
  gcr.io/proj/myapp
```

The shape that does the work: `-e KEY` with no `=value` tells
docker to inherit `KEY` from the parent process's env. `fnox exec`
decrypts the named secrets into that env; docker pulls only the
ones the user explicitly forwards. The secrets never touch disk,
shell history, or `docker inspect` output.

For many secrets, generate a docker env-file on the fly:

```bash
fnox exec -- bash -c '
  env | grep -E "^(DATABASE_URL|STRIPE_KEY|SESSION_SECRET)=" > .myapp.env
  docker run -d --rm --name myapp \
    -p "127.0.0.1:${HOST_PORT}:8080" \
    -e PORT=8080 --env-file .myapp.env \
    gcr.io/proj/myapp
  rm -f .myapp.env
'
```

Never `ENV API_KEY=...` in a Dockerfile — that bakes the secret
into the image layer forever and ships with every push.

---

## Worked example

User: "I have a Cloud Run service `myapp` at `gcr.io/proj/myapp`,
run it locally so I can test it."

Original gcloud command (whatever they're used to typing):

```bash
gcloud run deploy myapp \
  --image gcr.io/proj/myapp \
  --region us-east1 \
  --allow-unauthenticated \
  --set-env-vars LOG_LEVEL=debug
```

Drop `--region` and `--allow-unauthenticated` (no local analog;
surface the public-URL security caveat verbally before continuing).
Translate the rest:

```bash
# 1. Pick a free host port.
HOST_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1])")

# 2. Run the container.
docker run -d --rm --name myapp \
  -p "127.0.0.1:${HOST_PORT}:8080" \
  -e PORT=8080 \
  -e LOG_LEVEL=debug \
  gcr.io/proj/myapp

# 3. Wait for it to answer.
until curl -sS -o /dev/null --max-time 3 "http://127.0.0.1:${HOST_PORT}/"; do
  sleep 1
done

# 4. Expose via p2claw.
p2claw apps expose --port "${HOST_PORT}" myapp
```

If the user's gcloud command had `--no-allow-unauthenticated` (i.e.
IAP / IAM-gated on Cloud Run), translate that to `--auth-oauth`:

```bash
p2claw apps expose --port "${HOST_PORT}" myapp --auth-oauth
# or restrict providers:
p2claw apps expose --port "${HOST_PORT}" myapp --auth-oauth github,google
```

Visitors get redirected through p2claw's broker before reaching the
container; the verified identity arrives in `X-P2claw-*` request
headers. See `references/auth.md` for the full model.

If the container has secrets, wrap step 2 with `fnox exec --` and
add `-e <NAME>` per forwarded var (see *Secrets via fnox* above).

If the user gave you a `--source PATH` invocation instead of
`--image`, prepend `docker build -t myapp PATH` (or `pack build
myapp --path PATH --builder gcr.io/buildpacks/builder:latest` if
there's no Dockerfile) and use `myapp` as the image in step 2.

---

## Redeploys and cleanup

Same name → replace the running container before re-running:

```bash
docker rm -f myapp 2>/dev/null || true
# … then steps 1-4 again
```

To tear down completely:

```bash
docker rm -f myapp 2>/dev/null || true
p2claw unexpose myapp
```
