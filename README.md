# DevOps take-home

A small Python HTTP service, a Helm chart for it, a one-command kind setup, and a debugged
broken lab (Part 4). Everything runs locally.

| Part | Where |
|---|---|
| 1 Service + Dockerfile | `service/` |
| 2 Helm chart | `chart/` |
| 3 One-command setup | `setup.sh` |
| 4 Debug lab | `lab/` (fixed chart in `lab/broken-chart/`, notes in `lab/FINDINGS.md`, recording in `lab/part4-session.log`) |
| 5 Written question | `ANSWERS.md` |

## How to run and verify

Needs Docker, kind, kubectl and helm. Host ports 80 and 443 must be free, because the kind
cluster maps them for the ingress.

```bash
./setup.sh        # creates (or reuses) kind cluster "demo", installs ingress-nginx,
                  # builds and loads the image, installs release "demo" in namespace "demo"
./setup.sh        # safe to run again
```

The second run on an existing cluster exited with 0.

Verify:

```bash
kubectl --context kind-demo -n demo get pods,svc,ingress
curl -s -H "Host: demo.local" http://localhost/          # {"app": "demo", "version": "1.0.0", "pod": "demo-..."}
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: demo.local" http://localhost/healthz   # 200
```

The `Host` header is used so that nothing has to be added to `/etc/hosts`. To use the name in
a browser, add `127.0.0.1 demo.local` to `/etc/hosts`.

The ConfigMap change shows up without a pod restart:

```bash
kubectl --context kind-demo -n demo patch configmap demo --type merge -p '{"data":{"APP_NAME":"patched"}}'
# poll: curl -s -H "Host: demo.local" http://localhost/
```

In my test the patch was made at 18:35:38 and the new value first appeared at 18:36:08, and
both pods followed within about 50 seconds. This is the kubelet's ConfigMap sync delay, so a
check made a few seconds after the patch can still see the old value.

Part 4:

```bash
cd lab
./scenario.sh up && ./scenario.sh verify
```

Part 4 status: seven fixes are in `lab/broken-chart/`, but `verify` is **not** green (see
"What is not done").

## Design notes

- **Service:** Python standard library only (`http.server`), so there are no dependencies to
  patch. `APP_NAME` and `VERSION` are read on every request. A SIGTERM handler lets the process
  stop quickly; `docker stop` took 0.7 s in my test.
- **Dockerfile:** multi-stage, pinned base tag `python:3.12.7-slim-bookworm`, runs as numeric UID
  10001 (a numeric ID is needed for `runAsNonRoot`; I learned this in Part 4). The build stage
  only compiles the file, because there are no dependencies yet. It is a pattern, not a big
  saving.
- **Chart:** the port, image, config, resources and ingress host all come from `values.yaml`.
  The Service uses the named port `http`, so the port is defined in one place. A checksum
  annotation rolls the pods when the ConfigMap content changes at `helm upgrade`.
- **Config without restart:** the ConfigMap is mounted as files at `/etc/app-config` and the app
  reads the files first, then the environment. I did this because environment variables do not
  change in a running container: my first version (env only) did not follow a ConfigMap patch,
  which I confirmed by testing it.
- **Security context:** non-root, read-only root filesystem, no privilege escalation, all
  capabilities dropped.

## Resource requests and limits

| | CPU | Memory |
|---|---|---|
| requests | 50m | 64Mi |
| limits | 200m | 128Mi |

**Why:** the service is a tiny single-purpose HTTP server that answers with a few bytes of JSON.
These numbers are small on purpose so that two replicas fit easily on a kind node. The request
is lower than the limit so the pod can burst for a short time.

**I did not measure them.** I picked them by reasoning about the workload, and I used the same
numbers that the lab's LimitRange defaults suggest. I did not run a load test. In production I
would measure real usage first (for example with `kubectl top` or Prometheus) and set requests
close to normal usage.

## What I deliberately skipped, and the risk

- **The reporter in Part 4** (see below). Risk: `./scenario.sh verify` is not green.
- **TLS on the Ingress.** Risk: traffic is plain HTTP. Fine for a local demo, not for production.
- **A registry.** The image is built locally and loaded with `kind load`. Risk: this only works on
  kind. The tag is `local` with `IfNotPresent`, so a rebuilt image with the same tag is only
  picked up when the pods are restarted.
- **PodDisruptionBudget, anti-affinity, HPA, NetworkPolicy.** Risk: a node drain can take down both
  replicas, and there is no autoscaling or network isolation.
- **Automated tests and CI.** I did not do the optional pipeline (lint, build, Trivy). Risk: nothing
  scans the image or the chart automatically, so a vulnerable base image would not be noticed.
- **A production web server.** `http.server` is not meant for heavy traffic. Risk: low throughput and
  no real request limits.
- **Image pinned by tag, not digest**, and ingress-nginx pinned to `controller-v1.12.1`. Risk: a tag
  can move; a digest cannot.
- **ConfigMap change is not instant.** Risk: it takes up to about a minute to reach the pods.

## What I would change for production

- Push the image to a registry, pin it by digest, scan it with Trivy in CI and fail on HIGH/CRITICAL.
- Terminate TLS with cert-manager.
- Add a PodDisruptionBudget, topology spread or anti-affinity, an HPA, and NetworkPolicies.
- Use a real WSGI/ASGI server and structured logs; export metrics and set the resource numbers from data.
- ingress-nginx has reached end of life; I would plan the Gateway API migration described in
  `ANSWERS.md` instead of building more on it.

## What is not done

**Part 4 is not fully green.** Seven defects are fixed and each has an entry in `lab/FINDINGS.md`
(the brief says six). After the fixes, `./scenario.sh verify` still shows 4 failures:

- The reporter is not ready (`parse pod list: unexpected end of JSON input`). I could reproduce it
  on a fresh namespace after `./scenario.sh reset`, so it is not left-over state. I could not find
  the cause and did not guess a fix. `FINDINGS.md` has what I checked and what I would try next.
- `backend does not answer` and `gateway /status does not report backend=ok` fail even though both
  Deployments are `1/1` and the same requests work by hand. The script's own probe lost its first
  two output lines in three runs, which looks like a probe artefact. I did not modify `scenario.sh`.
- `reporter /report does not return a pod count` follows from the reporter problem.

## How I used AI

**Tool:** Claude (Anthropic) in a chat window, for the whole task.

**What it did:**
- Walked me through the environment setup and the Part 4 debugging step by step: it suggested
  `kubectl`/`helm` commands, I ran them and pasted the real output back, and the causes were worked
  out from that output.
- Drafted `service/app.py`, the Dockerfile, the Helm chart, `setup.sh`, `ANSWERS.md` and the wording
  of `lab/FINDINGS.md`. I ran and tested every part on my machine; the command output in this repo
  comes from my own cluster.

**What I had to correct** (the assistant or I got it wrong first):
- A suggested `docker inspect` failed because the image lives in the kind node's containerd; I
  switched to `crictl inspecti` through `docker exec`.
- The first version of the service read config from environment variables only, which does not
  follow a ConfigMap patch. I found this by testing, then switched to a mounted ConfigMap.
- The assistant's early test of the reporter on port 8080 was meaningless because the pods were not
  Ready, and a `head -5` on the reporter log showed old errors instead of the latest ones.
- The `emptyDir` experiment on the reporter was a wrong hypothesis; I reverted it (commit `61c8599`).
- An early draft contained placeholder text in another language, which I replaced with English.
- My own mistakes: lowercase `never` in `restartPolicy`, a wrong indentation of `volumeMounts`, a
  duplicated `resources:` key in `values.yaml`, and pasting a `<pod-name>` placeholder with the angle
  brackets. I caught them with `git diff`, Helm's error message and `cat -A`.
- Where there was a choice, I made it myself: I kept `runAsNonRoot: true` and added a numeric
  `runAsUser` instead of removing the check, I chose `restartPolicy: Never` for the Job, and I
  changed `common.port` to `8081` instead of setting `PORT` on every workload. I did not guess
  the UID: I read `65532` from the image's `/etc/passwd`.
- After the reporter still failed on a fresh namespace, I decided to stop and write it up as open
  instead of guessing a fix.

**What I did myself:** I ran every command myself and pasted the real output back. I did not apply anything blindly:
for long logs and files I asked for a summary, checked it against the raw output, and only then
acted on it. For every change I checked first (for example with `git diff`, `helm lint`,
`helm template` and `kubectl apply --dry-run`) and applied it after, and I re-read each change
before applying it. Code and commands drafted by Claude were reviewed by me before use. I tested
`setup.sh` twice and tested the ConfigMap patch behaviour myself. `FINDINGS.md`, `ANSWERS.md` and
this README were drafted with Claude and then reviewed by me against my own cluster output and my
recording, for example by checking that the pod names used in `FINDINGS.md` appear in
`part4-session.log`.
