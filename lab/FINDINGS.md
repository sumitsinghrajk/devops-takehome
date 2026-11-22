# Findings — Part 4 debug lab

I found seven separate causes, and the brief says six. I kept each one as its own entry
because I could not tell which two the author counts together. The reporter is still not
healthy, and I wrote that up honestly in the last section.

The session recording is `part4-session.log`. It includes my dead ends, for example the
`emptyDir` experiment on the reporter that I reverted in commit `61c8599`.

---

## Defect 1

**Symptom** (what you observed — paste the real command output):

`./scenario.sh up` did not install the chart cleanly:

```
Release "debug-lab" does not exist. Installing it now.
Error: 1 error occurred:
        * Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```

`helm list -n debug-lab` showed the release as `failed`, and the `migrate` Job did not exist.

**Cause** (the actual root cause, not the symptom restated):

`templates/migrate-job.yaml` had `restartPolicy: Always`. That is fine for a Deployment, but a Job only accepts `OnFailure` or `Never`. The API server rejected the Job, so Helm marked the whole release as failed.

**Fix** (what you changed, and why this over alternatives):

I changed it to `Never`. `OnFailure` would also be valid. I picked `Never` because every retry then starts a fresh pod and the failed pods stay around with their logs, which is the first thing I would want if a migration broke. The downside is that failed pods pile up, but `backoffLimit: 2` caps that.

**How I found it** (the sequence of commands/reasoning that led you here):

1. Ran `./scenario.sh up` and read the Helm error.
2. `helm list -n debug-lab` showed `failed`.
3. Opened `templates/migrate-job.yaml` and saw `restartPolicy: Always`.
4. My first edit was lowercase `never`, which is invalid because values are case sensitive. I caught it in `git diff` before applying it.
5. After the fix: `STATUS: deployed` and `migrate-s22k9   0/1   Completed`.

---

## Defect 2

**Symptom:**

All five Deployments were stuck at `0/1 CreateContainerConfigError`. `kubectl logs` only said the container was waiting to start, so it was no help. `kubectl describe pod` showed this in Events:

```
Warning  Failed  ...  kubelet  Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root (pod: "backend-794fdd8bbd-ktcvc_debug-lab(...)", container: backend)
```

**Cause:**

The templates set `runAsNonRoot: true`, but the image declares its user by name (`USER nonroot`), not by a number. The kubelet cannot prove that a named user is not root, so it refuses to start the container. The same securityContext is copied into every template, which is why all pods failed the same way.

**Fix:**

I kept `runAsNonRoot: true` and added `runAsUser` to all six workloads (5 Deployments and the migrate Job). The number comes from `common.runAsUser: 65532` in `values.yaml`, so it lives in one place. Removing `runAsNonRoot` would have made the error go away, but it would only hide the problem and weaken the security setting.

**How I found it:**

1. `kubectl get all -n debug-lab` showed all five pods in the same state, so I guessed one shared cause.
2. `kubectl logs` gave nothing useful because the container never started.
3. `kubectl describe pod` Events named `runAsNonRoot` and the non-numeric user.
4. `docker inspect` on my laptop failed with `no such object`, because the image was pulled by the kind node's own containerd. Through the node, `docker exec demo-control-plane crictl inspecti docker.io/ebinterview/eb-debug-app:1.0.1` showed `"uid": null, "username": "nonroot"`.
5. I did not want to guess the number. I pulled the same image digest locally (`sha256:17f41698...`, the same as on the node), copied `/etc/passwd` out with `docker create` and `docker cp`, and read `nonroot:x:65532:65532`.
6. After the fix, new pods started instead of `CreateContainerConfigError`.

---

## Defect 3

**Symptom:**

```
worker-5466b784f4-bl9xv   0/1   Error   3 (31s ago)   50s
```

Now `kubectl logs` worked, and the app said what it needed:

```
FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

**Cause:**

`templates/worker.yaml` sets `readOnlyRootFilesystem: true`, but the worker has to create `/var/cache/app` when it starts. I could only see this after Defect 2 was fixed, because before that the container never started.

**Fix:**

I added an `emptyDir` volume called `cache` and mounted it at `/var/cache/app`. I kept `readOnlyRootFilesystem: true`. The error also mentions `CACHE_DIR`, but pointing it at `/tmp` would not help, because `/tmp` is on the same read-only root filesystem.

**How I found it:**

1. `kubectl get pods` showed the worker in `Error` with restarts while the others were `Running`.
2. `kubectl logs` now worked and told me exactly what was missing.
3. My first edit had the wrong indentation. Helm said `YAML parse error ... line 58: mapping values are not allowed in this context`, and `cat -A` showed I had typed too many spaces before `volumeMounts:`.
4. After the fix, the new worker pod logged a normal start line instead of `FATAL`.

---

## Defect 4

**Symptom:**

backend, gateway and reporter were `Running` but `0/1`.

```
listening on :8081 (image default is 8081; set PORT to override)
Warning  Unhealthy  ...  kubelet  Readiness probe failed: Get "http://10.244.0.12:8080/healthz": dial tcp 10.244.0.12:8080: connect: connection refused
```

**Cause:**

The app listens on 8081 by default, but the chart used `common.port: 8080` for the containerPort, the probes and the Service `targetPort`. So the readiness probe was knocking on a port where nothing listened.

**Fix:**

I changed `common.port` to `8081` in `values.yaml`. That is one line, because the containerPort, both probes and the `targetPort` all read this value. The other option was to set `PORT: "8080"` as an env var on every workload, which means touching six places and leaving the image default and the chart disagreeing. I also left the Services' own ports alone (backend and reporter `8080`, gateway `80`). That way the addresses that clients use do not change, for example the gateway's `BACKEND_URL` that ends in `:8080`. One small leftover: the comment above `common.port` in `values.yaml` now sits next to `8081`, while clients still call the Services on `8080`.

**How I found it:**

1. `kubectl get pods` showed `Running` but `0/1`, which usually points at a readiness probe.
2. `kubectl logs` showed the app listening on 8081.
3. `kubectl describe pod` Events showed the probe failing against 8080.
4. `crictl inspecti` had also shown `ExposedPorts: 8081/tcp` in the image.
5. After the fix, backend and worker became `1/1 Running`.

---

## Defect 5

**Symptom:**

There was no new metrics pod at all. The old one was stuck in `CreateContainerConfigError`, and the new one never appeared.

```
NAME                 DESIRED   CURRENT   READY   AGE
metrics-6cd9c5666c   1         0         0       17m
```

`kubectl describe rs metrics-6cd9c5666c -n debug-lab` showed:

```
Warning  FailedCreate  ...  replicaset-controller  Error creating: pods "metrics-6cd9c5666c-kkg26" is forbidden: maximum cpu usage per Container is 1, but limit is 4
```

**Cause:**

`values.yaml` asked for `cpu: "2"` as the request and `cpu: "4"` as the limit for metrics. The namespace LimitRange `debug-lab-guardrails` (from `cluster-state/limits.yaml`) has `Max cpu 1` per container. The API server refused to create the pod, so the error is only visible on the ReplicaSet, not on a pod.

**Fix:**

I set metrics to `requests.cpu: "50m"` and `limits.cpu: "200m"`, the same as the other four workloads. I changed both values, because a request of 2 would not fit under a limit of 200m anyway. The memory values were already inside the allowed maximum, so I left them. I did not measure what metrics really needs, I only copied the other workloads' numbers, so this is a safe value and not a tuned one. `cluster-state/` was not touched.

**How I found it:**

1. There was no new metrics pod in `kubectl get pods`.
2. `kubectl get rs -n debug-lab -l app=metrics` showed `DESIRED 1 / CURRENT 0`.
3. `kubectl describe rs` showed the `FailedCreate` event with the exact reason.
4. I compared it with `kubectl describe limitrange -n debug-lab` and saw `Max cpu 1`.
5. After the fix: `metrics-7f497f58d5-xzw4r   1/1   Running`.

---

## Defect 6

**Symptom:**

The gateway was `Running` but `0/1` even after the port fix, while the backend was Ready.

```
readiness failed: backend not reachable: GET http://backend.default.svc:8080/healthz: ... lookup backend.default.svc on 10.96.0.10:53: no such host
Warning  Unhealthy  ...  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 503
```

**Cause:**

`gateway.env.BACKEND_URL` pointed to the namespace `default`, but the backend Service lives in `debug-lab` (`kubectl get svc -A | grep -E "backend|NAMESPACE"` showed `debug-lab   backend   ClusterIP   10.96.132.44   8080/TCP`).

**Fix:**

I set `BACKEND_URL: "http://backend.debug-lab.svc:8080"`. The port stays `8080`, because that is the Service port. The pod port `8081` is not used by clients.

**How I found it:**

1. The gateway was `0/1` while the backend was `1/1`, so it was not the port problem again.
2. `kubectl logs` showed the failed DNS lookup for `backend.default.svc`.
3. `kubectl get svc -A` showed the backend Service in `debug-lab`.
4. After the fix, a request from a busybox pod to the gateway returned `{"app":"gateway","backend":"ok","backend_url":"http://backend.debug-lab.svc:8080",...,"self":"ok",...}`.

---

## Defect 7

**Symptom:**

The reporter was `0/1`, and its log said:

```
pod list failed: kubernetes API returned HTTP 403: ... pods is forbidden: User "system:serviceaccount:debug-lab:reporter" cannot list resource "pods" in API group "" in the namespace "debug-lab"
```

`kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter` answered `no`.

**Cause:**

The RoleBinding `reporter-read` bound the Role to the ServiceAccount `default`, but the reporter runs as the ServiceAccount `reporter`.

**Fix:**

In `templates/rbac.yaml` I changed the subject name from `default` to `reporter`. I did not widen the Role, because the Role was already right and only the binding was wrong.

**How I found it:**

1. The log named the exact ServiceAccount that was denied.
2. `kubectl get rolebinding reporter-read -n debug-lab -o yaml | grep -A5 subjects` showed `name: default`.
3. After the fix, `kubectl auth can-i` went from `no` to `yes`, `./scenario.sh verify` showed PASS for "ServiceAccount debug-lab/reporter can list pods", and the reporter log changed from the 403 to a different error (next section).

---

If you ran out of time on any defect, say so here and describe what you would
have tried next — that section is read carefully and counts in your favour.

## Reporter: still open

I did not solve this one. This is what I know and what I do not know.

**What I see.** It happens on the running cluster, and it happened again after `./scenario.sh reset` and two `./scenario.sh up` runs, so it is not left-over state from my own debugging:

```
pod list failed: parse pod list: unexpected end of JSON input
GET /healthz -> 503
```

The reporter pod stays `0/1`. `/` returns 200, but `/healthz` and `/report` return 503.

**What I checked.**

- RBAC is fine. `kubectl get --raw "/api/v1/namespaces/debug-lab/pods" --as=system:serviceaccount:debug-lab:reporter` returns a valid PodList (45196 bytes at that time, in 0.13 s).
- From a pod using the reporter ServiceAccount, `curl` to the API returned `http=200 size=103789` (pretty-printed JSON). So the API answers fully.
- `diff reporter.yaml backend.yaml` shows only `serviceAccountName`, the `NAMESPACE` env from the downward API and the `.Values.reporter` references. The reporter container has no `args` or `command`, and its resources are the same as the others.
- `cluster-state/` only has a Namespace and a LimitRange. There is no NetworkPolicy and no ResourceQuota.
- I tried an `emptyDir` at `/var/cache/app` like the worker (commit `05201c0`). The log did not change, so I reverted it in `61c8599`.
- `kubectl debug` with a busybox ephemeral container: the process runs as UID 65532 and could not read `/proc/1/environ`. Dead end.

**Guesses, not proven.** The app might only read part of a large response (the PodList is bigger than 32 KiB and, pretty-printed, than 64 KiB). It might also need a writable path other than `/var/cache/app`. I found no chart setting for either guess, so I did not change anything for them.

**What I would try next.** I would check whether the failure depends on the number or size of pods, without deleting or disabling workloads because the rules forbid that. I would run a copy of the reporter pod with `kubectl debug --copy-to` and test a writable `/tmp` or extra env vars. I would also ask whether the author counts this as one of the six defects.

**Side note on `./scenario.sh verify`.** The backend and gateway checks fail even though both Deployments are `1/1` and the same requests work by hand (`200 OK`, and the gateway `/status` shows `"backend":"ok"`). I ran the script's own `incluster_probe` three times. Every time the first two lines (`PROBE_BACKEND` and `PROBE_GATEWAY_BODY`) were missing, and only `PROBE_REPORTER_BODY` and `PROBE_DNS` were printed. With `sleep 2` added to my own copy, `PROBE_BACKEND=ok` appeared. My guess is that output printed before `kubectl run -i` attaches gets lost, but I did not prove it. I did not change `scenario.sh`.

**Side note on `./scenario.sh up`.** On the first run, `limits.yaml` failed with `namespaces "debug-lab" not found`. `kubectl apply -f cluster-state/` applies files in alphabetical order, so the LimitRange came before the Namespace. A second `up` worked. Nothing in `cluster-state/` was changed.

## Reporter: follow-up experiments in an isolated namespace

To see whether the reporter fails because of the lab or because of the image, I ran it outside the lab, in a
separate namespace `rtest`: only the image, a ServiceAccount, a Role and a RoleBinding. No chart, no LimitRange, and
no lab workload was touched. The first three pods ran before I restarted my recording, so they are not in
`part4-session.log`. The last run (`t-plain`, `t-empty` and the `/report` loop) is in the recording.

| Pod | What was different | `/report` |
|---|---|---|
| `reporter-test` (alone in `rtest` at the time) | same securityContext and resources as the chart | `unexpected end of JSON input` |
| `t-rw` | `readOnlyRootFilesystem: false` | `unexpected end of JSON input` |
| `t-nolim` | no CPU/memory limits | `unexpected end of JSON input` |
| `t-plain` | no securityContext, no resources | `unexpected end of JSON input` |
| `t-empty` | `NAMESPACE=rempty`, a namespace with no pods | `{"namespace":"rempty","pod":"t-empty","pods":0}` |

What I take from this:

- The pod settings I could change in the chart (securityContext, resources, writable filesystem) make no difference.
- Authentication, TLS and the network path work: `t-empty` calls the same API with the same ServiceAccount and succeeds.
- The reporter fails when the pod list is not empty, and works when it has 0 pods.

I corrected two earlier guesses. The pod list being large because of my own debugging leftovers is not the cause
(`reporter-test` failed when it was the only pod). I also wrote earlier that a size limit was ruled out; that was too
strong. One pod is about 6 KB in this cluster, so a limit smaller than that is still possible, and I did not test it.

**Next step I did not get to:** in the empty namespace, add small pods one at a time and watch `t-empty`'s `/report`,
to find at which list size or pod count it starts to fail.
