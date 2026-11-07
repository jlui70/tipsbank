#!/usr/bin/env bash
# Ajustes de compliance nos workloads do kube-system criados pelo kubeadm e pelo
# manifest do Calico (etapa 4.1). kube-system esta no nivel "Audit" do Kyverno:
# nada e bloqueado ali, mas o PolicyReport mostra o que nao cumpre.
#  1. Labels de dono (app/team/env) — so metadata, nao reinicia pod.
#  2. CoreDNS: a imagem ja roda como nonroot (65532); aqui so DECLARA isso
#     (runAsUser/runAsNonRoot), o que causa um rolling restart das 2 replicas.
#  3. (4.6, compliance #2) calico-kube-controllers: a imagem ja roda como 10001 (USER da imagem);
#     declara no container.
#  4. (4.6, compliance #3) kube-proxy: o kubeadm nao poe livenessProbe. /livez na 10256
#     (healthzBindAddress padrao 0.0.0.0:10256; hostNetwork). /livez e o endpoint de
#     liveness puro (o /healthz tambem fica 503 quando o node esta sendo removido).
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

kubectl -n kube-system patch deploy calico-kube-controllers --type=strategic -p '{
  "spec":{"template":{"spec":{"containers":[{"name":"calico-kube-controllers",
    "securityContext":{"runAsUser":10001,"runAsGroup":10001,"runAsNonRoot":true}}]}}}}'
kubectl -n kube-system rollout status deploy/calico-kube-controllers --timeout=120s

kubectl -n kube-system patch ds kube-proxy --type=strategic -p '{
  "spec":{"template":{"spec":{"containers":[{"name":"kube-proxy",
    "livenessProbe":{"httpGet":{"host":"127.0.0.1","path":"/livez","port":10256},
                     "initialDelaySeconds":15,"periodSeconds":20,"timeoutSeconds":5,
                     "failureThreshold":6}}]}}}}'
kubectl -n kube-system rollout status ds/kube-proxy --timeout=300s
