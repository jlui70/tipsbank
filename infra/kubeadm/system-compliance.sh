#!/usr/bin/env bash
# Ajustes de compliance nos workloads do kube-system criados pelo kubeadm e pelo
# manifest do Calico (etapa 4.1). kube-system esta no nivel "Audit" do Kyverno:
# nada e bloqueado ali, mas o PolicyReport mostra o que nao cumpre.
#  1. Labels de dono (app/team/env) — so metadata, nao reinicia pod.
#  2. CoreDNS: a imagem ja roda como nonroot (65532); aqui so DECLARA isso
#     (runAsUser/runAsNonRoot), o que causa um rolling restart das 2 replicas.
# O que continua root de verdade (etcd, apiserver, scheduler, controller-manager,
# kube-proxy, calico-node) e excecao documentada no EVIDENCIAS (4.1/4.6).
# Reaplicar apos kubeadm upgrade ou reinstalacao do Calico (como system-resources.sh).
set -euo pipefail
label() { kubectl -n kube-system label --overwrite "$1" app="$2" team=plataforma env=producao; }
label deploy/coredns                 coredns
label deploy/calico-kube-controllers calico-kube-controllers
label ds/calico-node                 calico-node
label ds/kube-proxy                  kube-proxy

kubectl -n kube-system patch deploy coredns --type=strategic -p '{
  "spec":{"template":{"spec":{"containers":[{"name":"coredns",
    "securityContext":{"runAsUser":65532,"runAsGroup":65532,"runAsNonRoot":true}}]}}}}'
kubectl -n kube-system rollout status deploy/coredns --timeout=120s
