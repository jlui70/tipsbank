#!/usr/bin/env bash
# Etapa 3.5: kube-prometheus-stack no namespace tipsbank-monitoring (lab kubeadm).
# Pré-requisitos: cert-manager + ClusterIssuer tipsbank-ca (2.2) e ingress-nginx (2.1).
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
CHART_VERSION=92.21.2

# 4.5: so o namespace da plataforma de monitoring. Os namespaces do app (tipsbank-contas...) sao
# criados pelo chart helm/tipsbank; criar aqui por kubectl disputaria a posse com o Helm.
kubectl create namespace tipsbank-monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace tipsbank-monitoring --overwrite \
  app.kubernetes.io/part-of=tipsbank tipsbank.io/area=monitoring tipsbank.io/netpol=gerenciada-no-git
[[ -f "$DIR/secrets.yaml" ]] || "$DIR/gerar-secrets.sh"
kubectl apply -f "$DIR/secrets.yaml"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version "$CHART_VERSION" -n tipsbank-monitoring \
  -f "$DIR/values-kubeadm.yaml" -f "$DIR/values-mirror.yaml" --wait --timeout 10m

# 4.6 (compliance #3): livenessProbe dos 2 sidecars do Grafana, cada um na SUA porta de health
# (HEALTH_PORT em values-kubeadm.yaml). O chart so aceita uma probe igual para os dois. 60 s de
# folga: com limit de 100m de CPU o sidecar (Python) leva ~1 min para abrir o /healthz. Patch com
# field manager proprio: o helm upgrade (server-side apply) nao remove campos que nao sao dele.
kubectl -n tipsbank-monitoring patch deploy kps-grafana --type=strategic -p '{
  "spec":{"template":{"spec":{"containers":[
    {"name":"grafana-sc-dashboard",
     "livenessProbe":{"httpGet":{"path":"/healthz","port":8080},"initialDelaySeconds":60,
                      "periodSeconds":30,"timeoutSeconds":5,"failureThreshold":3}},
    {"name":"grafana-sc-datasources",
     "livenessProbe":{"httpGet":{"path":"/healthz","port":8081},"initialDelaySeconds":60,
                      "periodSeconds":30,"timeoutSeconds":5,"failureThreshold":3}}]}}}}'
kubectl -n tipsbank-monitoring rollout status deploy/kps-grafana --timeout=300s

# 4.5: dashboard, PrometheusRule e node-agent sao do chart helm/tipsbank (templates/monitoring/)
kubectl apply -f "$DIR/networkpolicy.yaml"      # etapa 4.3
