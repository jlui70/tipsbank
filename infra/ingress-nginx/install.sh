#!/usr/bin/env bash
# Instala/atualiza o Ingress NGINX Controller via Helm (etapa 2.1).
# Uso: ./infra/ingress-nginx/install.sh [arquivo-de-values]   (padrão: values-kubeadm.yaml)
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
VALUES=${1:-$DIR/values-kubeadm.yaml}
CHART_VERSION=4.15.1                 # controller v1.15.1 (última versão do projeto)

helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --version "$CHART_VERSION" \
  --namespace ingress-nginx --create-namespace \
  -f "$VALUES" \
  --wait --timeout 5m

kubectl -n ingress-nginx get pods -o wide
