#!/usr/bin/env bash
# Etapa 3.7 — Metrics Server (API metrics.k8s.io para kubectl top e HPA).
# Pré-requisitos: cert-manager (2.2) e kubelets com certificado da CA do cluster
# (infra/kubeadm/kubelet-serving-tls.sh).
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
VERSAO=3.14.0

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update metrics-server >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server --version "$VERSAO" \
  -n kube-system -f "$DIR/values-kubeadm.yaml" --wait --timeout 5m
kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=120s
