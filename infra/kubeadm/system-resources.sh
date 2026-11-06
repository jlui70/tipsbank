#!/usr/bin/env bash
# Etapa 3.4: requests/limits nos componentes de sistema que vêm sem (BestEffort ou sem limits).
# Valores = uso medido (kubelet Summary API, 2026-11-06) com folga de 2x a 4x na memória.
# Rodar de novo depois de: reinstalar o Calico (install-calico.sh), kubeadm upgrade (recria o
# DaemonSet kube-proxy) ou reinstalar o local-path (install-local-path.sh).
# `kubectl set resources` é idempotente: sem mudança, não há rollout.
set -euo pipefail

#                          namespace           objeto                          container                requests              limits
kubectl -n kube-system        set resources ds/kube-proxy                  -c kube-proxy             --requests=cpu=10m,memory=64Mi   --limits=cpu=200m,memory=256Mi
kubectl -n kube-system        set resources ds/calico-node                 -c calico-node            --requests=cpu=250m,memory=128Mi --limits=cpu=1,memory=512Mi
kubectl -n kube-system        set resources deploy/calico-kube-controllers -c calico-kube-controllers --requests=cpu=25m,memory=64Mi  --limits=cpu=200m,memory=256Mi
kubectl -n local-path-storage set resources deploy/local-path-provisioner  -c local-path-provisioner  --requests=cpu=10m,memory=64Mi  --limits=cpu=100m,memory=256Mi

kubectl -n kube-system rollout status ds/kube-proxy --timeout=5m
kubectl -n kube-system rollout status ds/calico-node --timeout=10m
kubectl -n kube-system rollout status deploy/calico-kube-controllers --timeout=5m
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=5m
