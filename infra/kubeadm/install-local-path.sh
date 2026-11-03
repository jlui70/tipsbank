#!/usr/bin/env bash
# StorageClass default do cluster kubeadm (ARQUITETURA §6: "local-path no kubeadm").
# O local-path-provisioner cria um diretório no nó (/opt/local-path-provisioner) para cada PVC.
# Não instala CRDs. No EKS o equivalente é a StorageClass gp3 do EBS CSI.
set -euo pipefail
VERSION=v0.0.37
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/$VERSION/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s
kubectl get storageclass
