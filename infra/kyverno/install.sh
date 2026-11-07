#!/usr/bin/env bash
# Instala/atualiza o Kyverno via Helm (etapa 4.1) e aplica as ClusterPolicies.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
CHART_VERSION=3.9.2

helm upgrade --install kyverno kyverno \
  --repo https://kyverno.github.io/kyverno/ \
  --version "$CHART_VERSION" \
  --namespace kyverno --create-namespace \
  -f "$DIR/values.yaml" -f "$DIR/values-mirror.yaml" \
  --wait --timeout 10m

# Etapa 4.3: NetworkPolicy zero-trust do namespace + opt-out do Generate do Kyverno
# (as NetPols deste namespace estao no Git).
kubectl label ns kyverno tipsbank.io/netpol=gerenciada-no-git --overwrite
kubectl apply -f "$DIR/networkpolicy.yaml"

# O chart nao tem livenessProbe para background/reports controller (compliance #3).
# Patch com server-side apply proprio (field manager separado): o helm upgrade
# nao remove campos que nao sao dele.
for c in background reports; do
  kubectl -n kyverno patch deploy "kyverno-$c-controller" --type=strategic -p '{
    "spec":{"template":{"spec":{"containers":[{"name":"controller",
      "livenessProbe":{"tcpSocket":{"port":8000},"initialDelaySeconds":15,
                       "periodSeconds":30,"timeoutSeconds":5,"failureThreshold":3}}]}}}}'
done
kubectl -n kyverno rollout status deploy --timeout=180s

# Excecoes ANTES das policies: senao, entre um apply e outro, o helper do
# local-path e o ingress-nginx ficam bloqueados (PVC e Ingress parados).
kubectl apply -f "$DIR/exceptions/"
kubectl apply -f "$DIR/policies/"
kubectl get cpol
