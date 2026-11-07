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

# Etapa 4.3: NetworkPolicy zero-trust + opt-out do Generate do Kyverno. So no kubeadm:
# o arquivo usa o IP do API server do lab (192.168.122.10); no EKS o control plane
# fala com os nodes por ENIs da VPC (seria ipBlock da VPC).
if [[ "$VALUES" == *values-kubeadm.yaml ]]; then
  kubectl label ns ingress-nginx tipsbank.io/netpol=gerenciada-no-git --overwrite
  kubectl apply -f "$DIR/networkpolicy.yaml"
fi

kubectl -n ingress-nginx get pods -o wide
