SHELL := /bin/bash

CLUSTER ?= wisecow
IMAGE   ?= ghcr.io/heyharshitrai/wisecow-devops
TAG     ?= v0.1.0
HOST    ?= wisecow.test
NS      ?= wisecow
CA_FILE ?= docs/wisecow-ca.crt

.PHONY: help cluster controllers image load deploy ca verify health health-json down clean

help:
	@echo "make cluster      create the kind cluster (pinned node image)"
	@echo "make controllers  install Traefik and cert-manager"
	@echo "make image        build the container image locally"
	@echo "make load         put that image inside the kind cluster"
	@echo "make deploy       apply manifests and roll the pods"
	@echo "make ca           pull the local CA out of the cluster into $(CA_FILE)"
	@echo "make verify       check the redirect and the certificate"
	@echo "make health       run both Problem Statement 2 scripts"
	@echo "make down         delete the cluster"
	@echo ""
	@echo "first run: make cluster controllers image load deploy ca verify"

cluster:
	kind create cluster --config kind/config.yaml --name $(CLUSTER)

controllers:
	helm repo add traefik https://traefik.github.io/charts
	helm repo update
	helm upgrade --install traefik traefik/traefik \
	  --namespace traefik --create-namespace \
	  --set service.spec.type=NodePort \
	  --set ports.web.nodePort=30080 \
	  --set ports.websecure.nodePort=30443 \
	  --set ports.web.allowACMEByPass=true \
	  --set ports.web.http.redirections.entryPoint.to=websecure \
	  --set ports.web.http.redirections.entryPoint.scheme=https \
	  --set ports.web.http.redirections.entryPoint.permanent=true \
	  --wait --timeout 5m
	kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml
	kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s

image:
	docker build -t $(IMAGE):$(TAG) .

load:
	kind load docker-image $(IMAGE):$(TAG) --name $(CLUSTER)

deploy:
	kubectl apply -f k8s/
	kubectl -n $(NS) set image deployment/wisecow wisecow=$(IMAGE):$(TAG)
	kubectl -n $(NS) rollout status deployment/wisecow --timeout=180s

ca:
	kubectl -n cert-manager get secret wisecow-ca \
	  -o jsonpath='{.data.tls\.crt}' | base64 -d > $(CA_FILE)
	@echo "wrote $(CA_FILE)"

verify:
	@echo "-- plain HTTP should redirect"
	@curl -sI http://$(HOST)/ | head -3
	@echo "-- HTTPS, verified against the local CA"
	@curl -s --cacert $(CA_FILE) https://$(HOST)/
	@echo "-- certificate"
	@kubectl -n $(NS) get certificate

health:
	bash scripts/system_health_monitor.sh
	python3 scripts/app_health_checker.py --url https://$(HOST) --cacert $(CA_FILE)

health-json:
	bash scripts/system_health_monitor.sh --json
	python3 scripts/app_health_checker.py --url https://$(HOST) --cacert $(CA_FILE) --json

down:
	kind delete cluster --name $(CLUSTER)

clean: down
	-docker rmi $(IMAGE):$(TAG)
	-rm -f $(CA_FILE)
