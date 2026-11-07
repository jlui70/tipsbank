#!/usr/bin/env bash
# Plataforma do TipsBank num cluster kubeadm com CNI (Calico, infra/kubeadm/install-calico.sh).
# Depois dele, o banco inteiro sobe com UM comando:
#   helm install tipsbank oci://ghcr.io/jlui70/charts/tipsbank --version 1.0.0 \
#     -n tipsbank --create-namespace -f helm/tipsbank/values-prod.yaml
#
# Por que separado do chart (decisao 4.5): sao os OPERADORES do cluster (CRDs, webhooks,
# controllers). O chart do app traz os OBJETOS deles (ClusterPolicy, ServiceMonitor,
# PrometheusRule, Ingress, Certificate via anotacao). Assim:
#   - nao ha problema de ordem de CRD (o Helm nao instala CRD e objeto do CRD na mesma release
#     sem hooks: "no matches for kind ClusterPolicy");
#   - um `helm uninstall tipsbank` NAO desliga o Kyverno nem o monitoring do cluster.
#
# Ordem (cada passo depende do anterior):
#   1. StorageClass default (local-path) + NetPol + helper endurecido
#   2. kubelet serving TLS (metrics-server verifica o certificado do kubelet)
#   3. cert-manager + ClusterIssuers da CA do lab
#   4. metrics-server (APIService com certificado do cert-manager)
#   5. ingress-nginx
#   6. kube-prometheus-stack (webhook com certificado do cert-manager)
#   7. Kyverno + excecoes dos componentes de plataforma
#   8. ajustes do kube-system (resources, labels, CoreDNS) e audit log do API server
set -euo pipefail
INFRA=$(cd "$(dirname "$0")/.." && pwd)
passo() { printf '\n===== %s =====\n' "$*"; }

passo "1/8 local-path";            "$INFRA/kubeadm/install-local-path.sh"
passo "2/8 kubelet serving TLS";   "$INFRA/kubeadm/kubelet-serving-tls.sh"   # reinicia o kubelet de cada node, um por vez
passo "3/8 cert-manager";          "$INFRA/cert-manager/install.sh"
passo "4/8 metrics-server";        "$INFRA/metrics-server/install.sh"
passo "5/8 ingress-nginx";         "$INFRA/ingress-nginx/install.sh"
passo "6/8 kube-prometheus-stack"; "$INFRA/monitoring/install.sh"
passo "7/8 Kyverno";               "$INFRA/kyverno/install.sh"
passo "8/8 kube-system + audit";   "$INFRA/kubeadm/system-resources.sh"; "$INFRA/kubeadm/system-compliance.sh"
if [[ "${AUDIT_LOG:-1}" == "1" ]]; then "$INFRA/kubeadm/audit-log.sh"; fi

passo "plataforma pronta"
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | head
echo "Proximo passo: helm install tipsbank ... (ver comentario no topo)"
