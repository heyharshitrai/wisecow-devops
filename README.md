# wisecow on Kubernetes

A small end-to-end exercise: take a toy service, containerise it, run it on Kubernetes,
terminate TLS in front of it, and rebuild it automatically on every commit.

The app is a 573-byte bash script that serves a fortune-telling cow over a raw netcat
socket. It works fine on a normal Ubuntu machine. Move it anywhere else and it breaks in
four specific ways.

`app/wisecow.sh` is byte-identical to
[upstream](https://github.com/nyrahul/wisecow) —
`sha256 7531eee4983f90db84fcdb3cba0258b8f4f72adf387a664d6cea0c06e4760ac9`. Nothing about the
application changed. Everything here is packaging.

## About the demo

All of this runs on a local `kind` cluster on one machine. `wisecow.test` is a hostname that
exists only in that machine's `/etc/hosts` file. It does not resolve anywhere else, and there
is no public deployment of this. The steps below get you a running cluster and a working
certificate in about four minutes.

## Try it

You need Docker with BuildKit, `kind`, `kubectl`, `helm` and `make` on your PATH, and about
2 GB of disk. Each step below is one `make` target, and the Makefile is short enough to read
if you would rather run the equivalent `kind`/`kubectl`/`helm` commands yourself.

```bash
make cluster        # single-node kind cluster, node image pinned by digest
make controllers    # Traefik + cert-manager
make image          # build the container
make load           # put that image inside the cluster
make deploy         # apply manifests, roll the pods
make ca             # pull the local CA out to docs/wisecow-ca.crt
sudo sh -c 'echo "127.0.0.1 wisecow.test" >> /etc/hosts'
make verify
```

`make verify` should show a permanent redirect on plain HTTP, then a cow over HTTPS with a
certificate that validates against the CA you just exported.

To get the padlock in a browser rather than only in curl:

```bash
sudo cp docs/wisecow-ca.crt /usr/local/share/ca-certificates/wisecow-ca.crt
sudo update-ca-certificates
# Firefox keeps its own store: Settings > Privacy & Security > Certificates > View
# Certificates > Authorities > Import, and tick "trust this CA to identify websites"
```

Then open <https://wisecow.test>. That name only resolves once the `127.0.0.1` line above is
in your hosts file, so it will not load before that step.

`make down` deletes the cluster when you are finished with it.

## What is in here

| Path | What it is |
|---|---|
| `Dockerfile` | Debian slim, pinned by digest, non-root, read-only root filesystem |
| `LICENSE` | Apache-2.0, same as upstream |
| `app/wisecow.sh` | the upstream script, unmodified |
| `k8s/` | numbered manifests, `00-namespace` through `10-pdb`, applied in that order |
| `kind/config.yaml` | cluster definition with host ports 80/443 forwarded in |
| `.github/workflows/ci.yaml` | build, smoke test, scan, publish |
| `.github/workflows/cd.yaml` | deploy, switched off by default (see below) |
| `scripts/` | the two Problem Statement 2 scripts |
| `kubearmor/` | two policy objects, clearly marked as extras |
| `docs/evidence/` | real command output from this build, not screenshots of prose |

## How a request gets there

```
browser
  │  https://wisecow.test :443
  ▼
Traefik  (NodePort 30443 on the node, mapped to host :443)
  │  holds wisecow-tls, issued by cert-manager from a local CA
  │  redirects :80 to :443, retries refused connections up to 3 times
  ▼
Service wisecow  ClusterIP :80 → :4499
  ▼
Pod (2 replicas)  container runs as uid 10001, root filesystem read-only
  └─ bash wisecow.sh → nc -lN 4499 → fortune | cowsay
```

TLS ends at the ingress. Traffic from the ingress to the pod is plain HTTP inside the
cluster. That is ordinary for a setup this size, but it is worth saying out loud rather than
leaving as an assumption. Encrypting that hop too would mean a service mesh, which is a lot
of machinery for one toy app.

## Decisions

**Debian, not Alpine.** Alpine ships `cowsay` only in `testing`, has no `fortune-mod`
package at all, and its default `nc` is busybox, which has no `-N` flag. Making Alpine work
means pinning a testing repository and building cowsay from source. Debian's
`bookworm-slim` installs everything in one `apt-get` line. The image comes out at 195 MB and
most of that is perl, which cowsay needs.

There is no `ca-certificates` in the image either. The app makes no outbound TLS calls, so it
earns nothing there. That is the sort of package to add the day it becomes true rather than
preemptively.

The four things that break if you package this carelessly are all reproduced in
`docs/evidence/04-docker-traps.txt`, because describing a failure from memory is not the
same as having seen it:

1. `nc -lN` needs `netcat-openbsd`. `netcat-traditional` gives you
   `nc: invalid option -- 'N'` and a container that will not start.
2. `cowsay` and `fortune` install to `/usr/games`, which is not on PATH in a non-login
   shell. Without `ENV PATH`, the script's own prerequisite check fires and exits 1.
3. `fortune-mod` only *recommends* a data package, so `--no-install-recommends` without
   `fortunes-min` leaves you with "No fortunes found".
4. The script runs `mkfifo response` in its working directory. Under
   `readOnlyRootFilesystem: true` that fails with "Read-only file system" and — this is the
   part that catches people — **the container keeps running**. It does not crash, so a
   restart policy will not save you. The readiness probe is what catches it.

The script lives at `/usr/local/bin/wisecow.sh` and the working directory is
`/var/lib/wisecow`, which is where the `emptyDir` gets mounted. If both were the same path,
the volume would shadow the binary and the container would fail to start on a read-only root
filesystem. Keeping them apart avoids the problem entirely.

**`fsGroup: 10001`.** Kubernetes hands the `emptyDir` to that group, so the process can write
to it. Plain `docker run` does no such thing — the tmpfs arrives as root:root 0755 and the
container starts looping on "Permission denied". That is why the CI smoke test spells out
`--tmpfs /var/lib/wisecow:rw,size=8m,uid=10001,gid=10001,mode=0770`. It also matters that
the error changes from "Read-only file system" to "Permission denied"; the second one is
harder to read when you are tired.

**A private CA instead of a bare self-signed certificate.** A `selfSigned` issuer can only
sign certificates with themselves, which gives you a chain of length one and nothing useful
to import. So the repo builds a real CA, signs the leaf with it, and exports the CA. You get
a normal two-certificate chain, and once you import that CA every local hostname you add
later is trusted without further work. `curl --cacert docs/wisecow-ca.crt` reports
`Verify return code: 0 (ok)` over TLS 1.3.

**Traefik instead of ingress-nginx.** ingress-nginx went end-of-life in March 2026 and takes
no further security fixes. Shipping an abandoned ingress controller in something written to
be read closely seemed like the wrong first impression, so this uses Traefik. The cost is
that every cert-manager tutorial on the internet assumes nginx, so the annotations differ
and you have to know which ones matter.

There is a Let's Encrypt issuer committed at `04-clusterissuer-letsencrypt.yaml` and it is
deliberately unused. It is what you would point the Ingress at on a cluster with a real DNS
name. It cannot work here, because `wisecow.test` does not resolve publicly and HTTP-01
validation has nowhere to go. Traefik's `allowACMEByPass` is switched on anyway, since the
`:80` redirect would otherwise break the `/.well-known/acme-challenge` path the moment
somebody enables that issuer.

**GHCR with `GITHUB_TOKEN`, not Docker Hub credentials.** `permissions: packages: write`
plus the runner's own token means there is no long-lived registry secret sitting in the repo
waiting to leak. Images are tagged `sha-<short>`; `latest` gets published as a convenience
but the Deployment never references it.

**tini with `-e 143`.** bash does not forward SIGTERM, so without an init every rollout sits
in `Terminating` for the full grace period. The exit-code remap fixes something smaller:
bash dies with 143, the pod briefly shows `Error`, and anyone watching `kubectl get pods`
during a deploy sees a scary word for no reason.

**The Trivy gate uses `--ignore-unfixed`.** Count the findings without it and the image
reports 60 HIGH/CRITICAL entries, of which **zero have a fixed version available**. Debian
has marked all of them `affected`, `fix_deferred` or `will_not_fix`. A gate on severity
alone would be red forever and everyone would learn to ignore it within a week. With
`--ignore-unfixed` the count is 0 today and the build breaks the moment Debian actually
publishes a patch.

## What is actually wrong with it

The app serves one connection per loop iteration:

```bash
while [ 1 ]; do
  cat $RSPFILE | nc -lN $SRVPORT | handleRequest
  sleep 0.01
done
```

Between `nc` exiting and the next `nc` binding, the port is closed for a few milliseconds.
Anything arriving in that window is refused, and Traefik reports it as a 502. Measured on
this cluster with 2 replicas and the retry middleware:

| Load | Result |
|---|---|
| 60 requests, 200 ms apart (three rounds of 20) | 59/60 |
| 60 requests, back to back (three rounds of 20) | 58/60 |
| 10 concurrent, three rounds | 4/10, 4/10, 4/10 |
| 30 requests straight to a pod, no ingress | 30/30 |

Those first two lines move around between runs. A later 25-request run came back 25/25. Call
it one request in fifty through the ingress, and only when the timing lands badly. A person
clicking around will probably never see it. That is not the same as the service being
reliable, and I am not going to describe it as if it were.

Under real concurrency it fails about half the time. No amount of retrying fixes a server
that can only hold one connection. The retry middleware in `k8s/05-middleware-retry.yaml` is
a mitigation and is labelled as one in the file itself.

A few other things a reviewer should know before trusting any of this:

The response is not valid HTTP. `wisecow.sh` writes `HTTP/1.1 200` with no reason phrase and
no `Content-Length`, then closes the socket to signal the end of the body. curl, Python's
`http.client` and Kubernetes' probes all tolerate it; a stricter client would not. I checked
rather than assumed. The Python case is in `docs/evidence/03-concurrency.txt`, and the pods
in `docs/evidence/01-cluster.txt` are `Ready`, which means those `httpGet` probes have been
parsing that status line every few seconds without failing.

CD is switched off. GitHub's runners cannot reach a kind cluster on a laptop, so a deploy
step would either fail on every push or quietly do nothing. Neither is worth shipping.
`cd.yaml` is real and correct, gated behind `vars.CD_ENABLED`. The local equivalent,
`kubectl set image` followed by `kubectl rollout status`, was run and is in the evidence.

The NetworkPolicy does nothing on this cluster. kind's default CNI is kindnet, which does not
implement NetworkPolicy. The object is correct and it is inert. It needs Calico or Cilium
before it means anything.

The KubeArmor policies are untested. KubeArmor is not installed here, so those two files are
configuration rather than a verified claim.

It is a single-node cluster with one ingress replica. No high availability, no node drain
tested, no HPA because metrics-server is not installed.

And the leaf certificate has no CN. cert-manager stopped setting one; browsers validate the
SAN, which is `DNS:wisecow.test`, and the chain verifies. It looks odd when you run it
through `openssl`, which is worth knowing before somebody else notices.

## What I would do next

1. Replace the `nc` loop with `socat TCP-LISTEN:4499,reuseaddr,fork` or an actual HTTP
   server. That fixes the concurrency problem instead of hiding it behind retries.
2. Turn on CD against a cluster a runner can reach. The workflow is already written.
3. Move to Gateway API. Ingress is on its way out and Traefik supports both.
4. Install KubeArmor on this cluster and prove the policies block something.
5. Turn the manifests into a Helm chart with per-environment values, so the image tag is a
   value rather than something `kubectl set image` rewrites.

## Assessment mapping

Problem Statement 1 is the Dockerfile, the manifests and Service in `k8s/`, CI in `ci.yaml`,
CD in `cd.yaml`, and TLS through cert-manager. The repository has to be public when it is
submitted, which is a setting on the repository rather than a file in it.

Problem Statement 2, objective 1 is `scripts/system_health_monitor.sh`: CPU, memory, disk
and process count against thresholds, optional required-process checks, line or JSON output,
a log file, and exit code 1 on any breach.

Problem Statement 2, objective 4 is `scripts/app_health_checker.py`: standard library only,
retries, latency tracking, and certificate validation when you pass `--cacert`. It is
pointed at the deployment in this repo.

Evidence for all of it is in `docs/evidence/`.
