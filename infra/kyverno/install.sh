#!/usr/bin/env bash
# Instala/atualiza o Kyverno via Helm (etapa 4.1) e aplica as ClusterPolicies.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
CHART_VERSION=3.9.2

helm upgrade --install kyverno kyverno \
  --repo https://kyverno.github.io/kyverno/ \
  --version "$CHART_VERSION" \
  --namespace kyverno --create-namespace \
  -f "$DIR/values.yaml" \
  --wait --timeout 10m

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

kubectl apply -f "$DIR/policies/"
kubectl apply -f "$DIR/exceptions/"
kubectl get cpol
