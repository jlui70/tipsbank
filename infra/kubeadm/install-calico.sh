#!/usr/bin/env bash
# Instala o Calico (CNI com suporte a NetworkPolicy — necessário na etapa 2.5).
# Manifest "calico.yaml" (sem Tigera operator). Pool = --pod-network-cidr do kubeadm init.
set -euo pipefail
CALICO_VERSION=v3.33.0
POD_CIDR=10.244.0.0/16
curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml \
  | sed -e 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' \
        -e "s|#   value: \"192.168.0.0/16\"|  value: \"$POD_CIDR\"|" \
  > /tmp/calico.yaml
grep -A1 'name: CALICO_IPV4POOL_CIDR' /tmp/calico.yaml
kubectl apply -f /tmp/calico.yaml
