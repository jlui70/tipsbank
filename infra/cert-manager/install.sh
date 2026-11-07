#!/usr/bin/env bash
# Instala/atualiza o cert-manager via Helm e cria os emissores do lab (etapa 2.2).
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
CHART_VERSION=v1.21.3

helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --version "$CHART_VERSION" \
  --namespace cert-manager --create-namespace \
  -f "$DIR/values.yaml" \
  --wait --timeout 5m

# Etapa 4.3: NetworkPolicy zero-trust do namespace + opt-out do Generate do Kyverno
# (as NetPols deste namespace estao no Git).
kubectl label ns cert-manager tipsbank.io/netpol=gerenciada-no-git --overwrite
kubectl apply -f "$DIR/networkpolicy.yaml"

# Sem o Job startupapicheck: espera o webhook responder antes de criar os emissores
# (o API server consulta o webhook do cert-manager para validar Certificate/ClusterIssuer).
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s
for i in $(seq 30); do
  kubectl apply --dry-run=server -f "$DIR/cluster-issuers.yaml" >/dev/null 2>&1 && break
  sleep 2
done
kubectl apply -f "$DIR/cluster-issuers.yaml"
kubectl -n cert-manager wait --for=condition=Ready certificate/tipsbank-ca --timeout=120s
kubectl get clusterissuer
