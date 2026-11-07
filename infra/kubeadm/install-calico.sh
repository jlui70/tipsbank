#!/usr/bin/env bash
# Instala o Calico (CNI com suporte a NetworkPolicy — necessário na etapa 2.5).
# Manifest "calico.yaml" (sem Tigera operator). Pool = --pod-network-cidr do kubeadm init.
set -euo pipefail
CALICO_VERSION=v3.33.0
POD_CIDR=10.244.0.0/16
curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml \
  | sed -e 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' \
        -e "s|#   value: \"192.168.0.0/16\"|  value: \"$POD_CIDR\"|" \
        -e "s|quay.io/calico/calico:$CALICO_VERSION|ghcr.io/jlui70/mirror/calico/calico:$CALICO_VERSION@sha256:3eba6eb95b51b337bf255ecaf5c669b4b2ba04f9f813aa89785aa6853ecf9817|g" \
        -e "s|quay.io/calico/node:$CALICO_VERSION|ghcr.io/jlui70/mirror/calico/node:$CALICO_VERSION@sha256:224903e17a8d0588a6b9781331bd64935b0ef741a4208043f7dd9fcc834fc7cd|g" \
        -e "s|quay.io/calico/third-party-cni-plugins:$CALICO_VERSION|ghcr.io/jlui70/mirror/calico/third-party-cni-plugins:$CALICO_VERSION@sha256:ae6464c7d8ffae03f2f26ed411a5b69e91baf31d8d538923645459f4f301a917|g" \
  > /tmp/calico.yaml
# Etapa 4.3: as 3 imagens do Calico vem do espelho ghcr.io/jlui70/mirror (infra/mirror/imagens.txt),
# pinadas por digest. Conferir que nao sobrou nenhuma do quay.io:
! grep -n 'image: .*quay.io' /tmp/calico.yaml
grep -A1 'name: CALICO_IPV4POOL_CIDR' /tmp/calico.yaml
kubectl apply -f /tmp/calico.yaml
