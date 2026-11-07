#!/usr/bin/env bash
# StorageClass default do cluster kubeadm (ARQUITETURA §6: "local-path no kubeadm").
# O local-path-provisioner cria um diretório no nó (/opt/local-path-provisioner) para cada PVC.
# Não instala CRDs. No EKS o equivalente é a StorageClass gp3 do EBS CSI.
set -euo pipefail
VERSION=v0.0.37
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/$VERSION/deploy/local-path-storage.yaml
# Etapa 4.1: provisioner nao-root + labels de dono, helper pod com imagem fixa
# (sem :latest). Reaplicar este script reaplica os patches.
DIR=$(cd "$(dirname "$0")" && pwd)
kubectl -n local-path-storage patch deploy local-path-provisioner --type=strategic \
  --patch-file "$DIR/local-path-provisioner-patch.yaml"
kubectl -n local-path-storage patch configmap local-path-config --type=merge \
  -p "$(jq -n --rawfile helper "$DIR/local-path-helper-pod.yaml" '{data: {"helperPod.yaml": $helper}}')"

kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s
kubectl get storageclass
