# Running this on a real cluster

The rest of the repo runs on a laptop. This directory is the small amount of
extra config needed to put the same manifests on a public machine with a real
Let's Encrypt certificate.

It is deliberately thin. `k8s/` is provider-agnostic and stays that way; the
only things that change are the hostname and which issuer signs the
certificate.

## What it provisions

A single-node [k3s](https://k3s.io) cluster on a t3.small, behind an Elastic IP,
serving the app on `https://<ip-dashed>.sslip.io`.

`sslip.io` is public wildcard DNS that maps any `<ip-with-dashes>.sslip.io`
name back to that IP. It exists so HTTP-01 validation has a real hostname to
resolve without anybody buying a domain.

k3s matters here for two reasons: it ships Traefik, which is the same ingress
controller the local setup uses, and its ServiceLB binds the host's ports 80
and 443 directly, so there is no cloud load balancer to pay for or configure.

## Prerequisites

- Ubuntu 24.04, 2 GB RAM, public IPv4
- Security group: 22 from your address, **80 and 443 from anywhere**
- An Elastic IP, associated

Port 80 is not optional. Let's Encrypt fetches a file over plain HTTP to prove
you control the name. Close it and no certificate is ever issued.

## Run it

```bash
git clone https://github.com/heyharshitrai/wisecow-devops
cd wisecow-devops
bash deploy/ec2/install.sh
```

Takes about three minutes. Override the hostname if you have your own domain
pointed at the box:

```bash
HOST=wisecow.example.com bash deploy/ec2/install.sh
```

## What it actually does

1. Installs k3s if it isn't there
2. Applies `00-traefik-config.yaml`, which sets `allowACMEByPass`
3. Installs cert-manager
4. Applies `k8s/`
5. Applies `10-ingress.yaml`, which replaces the local Ingress with one for the
   sslip.io hostname and the `letsencrypt-prod` issuer
6. Points the Deployment at `sha-<current main>` in GHCR
7. Waits for the certificate

Step 2 is the one that matters. k3s's Traefik redirects `:80` to `:443` by
default, which is what you want for visitors and fatal for ACME: the challenge
lives at `http://<host>/.well-known/acme-challenge/<token>`, and a redirect
breaks it. `allowACMEByPass` lets that one path through unredirected.

## Verifying it

```bash
curl -sI https://<host>/          # expect 308, Location: https://...
curl -s  https://<host>/ | head   # expect a cow
echo | openssl s_client -connect <host>:443 -servername <host> 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```

The issuer should be Let's Encrypt. If it says anything about `wisecow.test`,
you are looking at the local CA and the ingress did not swap.

## Teardown

The link lives only as long as the Elastic IP is attached to a running
instance. When you are done:

```bash
# on the box, or skip straight to the console
sudo k3s-uninstall.sh

# then, from wherever your AWS CLI lives
aws ec2 terminate-instances --instance-ids <id>
aws ec2 release-address --allocation-id <alloc-id>
aws ec2 delete-security-group --group-name <sg>
aws ec2 delete-key-pair --key-name wisecow-ec2
```

Releasing the Elastic IP is the step that actually kills the URL. Leaving it
allocated but unattached costs money and serves nothing.

## Cost

t3.small in ap-southeast-2 is about $0.023/hr, plus ~$1.60/month for the 20 GB
volume. Call it **$18/month** if left running. Stop the instance when you are
not demonstrating it and you pay only for storage, but the link goes dark while
it is stopped.

## Known limitations

Same as the local setup, plus one. The app still serves one connection at a
time, so concurrent load will fail about half the time — there is a table of
measurements in the main README. And a single node means a single point of
failure: reboot the instance and the URL 503s until k3s comes back up, which
takes about thirty seconds.
