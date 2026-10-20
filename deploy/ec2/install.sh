#!/usr/bin/env bash
#
# Brings up the cloud demo on a fresh Ubuntu 24.04 box with a public IP.
#
#   bash deploy/ec2/install.sh
#
# Overridable:
#   HOST=<fqdn>        hostname to serve and to request a certificate for
#   IMAGE_TAG=<tag>    image tag to run, defaults to sha-<current main>
#
# Assumes the box has ports 80 and 443 open and nothing already listening on
# them. Takes about three minutes, most of it waiting for Let's Encrypt.
set -euo pipefail

REPO_SLUG="${REPO_SLUG:-heyharshitrai/wisecow-devops}"
HOST="${HOST:-$(curl -s --max-time 10 https://ifconfig.me | tr '.' '-').sslip.io}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"

say() { printf '\n== %s\n' "$*"; }
kc() { sudo k3s kubectl "$@"; }

say "host is $HOST"

if ! command -v k3s >/dev/null 2>&1; then
  say "installing k3s"
  curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
  sudo sh /tmp/k3s-install.sh --write-kubeconfig-mode 644
fi

say "waiting for the node to be Ready"
for _ in $(seq 1 60); do
  [ "$(kc get nodes --no-headers | awk '{print $2}')" = "Ready" ] && break
  sleep 3
done
kc get nodes

say "patching traefik so the ACME challenge survives the :80 redirect"
kc apply -f deploy/ec2/00-traefik-config.yaml
kc -n kube-system rollout status deploy/traefik --timeout=180s

say "installing cert-manager $CERT_MANAGER_VERSION"
kc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
kc -n cert-manager rollout status deploy/cert-manager-webhook --timeout=240s

say "applying k8s/"
kc apply -f k8s/

say "swapping in the cloud ingress"
if [ "$HOST" = "54-153-164-134.sslip.io" ]; then
  kc apply -f deploy/ec2/10-ingress.yaml
else
  sed "s/54-153-164-134\.sslip\.io/${HOST}/g" deploy/ec2/10-ingress.yaml | kc apply -f -
fi

# The local Ingress issued wisecow-tls from the private CA. Nothing references
# it any more and it would just show up as clutter in `kubectl get certificate`.
kc -n wisecow delete certificate wisecow-tls --ignore-not-found

say "pointing the deployment at the current main build"
if [ -z "${IMAGE_TAG:-}" ]; then
  IMAGE_TAG="$(python3 -c "
import json, urllib.request
sha = json.load(urllib.request.urlopen(
    'https://api.github.com/repos/${REPO_SLUG}/commits/main'))['sha']
print('sha-' + sha[:7])
")"
fi
echo "image tag: $IMAGE_TAG"
kc -n wisecow set image deployment/wisecow "wisecow=ghcr.io/${REPO_SLUG}:${IMAGE_TAG}"
kc -n wisecow rollout status deployment/wisecow --timeout=180s

say "waiting for Let's Encrypt to issue"
for _ in $(seq 1 60); do
  [ "$(kc -n wisecow get certificate wisecow-tls-le \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" = "True" ] && break
  sleep 5
done
kc -n wisecow get certificate

say "serving"
curl -sS --max-time 15 "https://${HOST}/" | head -8
echo
echo "open https://${HOST}/"
