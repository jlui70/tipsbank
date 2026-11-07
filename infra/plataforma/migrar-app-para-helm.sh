#!/usr/bin/env bash
# Migracao UNICA (etapa 4.5): o app aplicado por kubectl (k8s/, etapas 1.4-4.4) passa a ser
# gerenciado so pelo Helm (helm/tipsbank). A plataforma (infra/) fica como esta.
#
# ATENCAO: APAGA os namespaces do app -> o banco volta ao seed do init.sql e a trilha de auditoria
# recomeca (decisao do usuario em 2026-11-07: dados do lab sao de teste). A trilha antiga continua
# na VM NFS da 1.6 (192.168.122.13:/srv/nfs/auditoria), que nao e tocada.
#
# Uso: ./infra/plataforma/migrar-app-para-helm.sh [--sim]   (--sim pula a confirmacao)
set -euo pipefail
RELEASE=${RELEASE:-tipsbank}; RNS=${RNS:-tipsbank}
APP_NS="tipsbank-contas tipsbank-transacoes tipsbank-auditoria tipsbank-web tipsbank-loadtest"

if [[ "${1:-}" != "--sim" ]]; then
  read -r -p "Apagar os namespaces do app ($APP_NS) e os dados de teste? [digite SIM] " r
  [[ "$r" == "SIM" ]] || { echo "cancelado"; exit 1; }
fi

# 1. ADOTAR o que ja existe fora dos namespaces do app e que o chart passa a gerenciar.
#    Com as anotacoes da release, o helm install assume o objeto em vez de falhar com
#    "exists and cannot be imported". Sem janela: as policies Kyverno NUNCA saem do ar.
adotar() {  # tipo nome [namespace]
  local ns=(); [[ -n "${3:-}" ]] && ns=(-n "$3")
  kubectl "${ns[@]}" get "$1" "$2" >/dev/null 2>&1 || return 0
  kubectl "${ns[@]}" annotate "$1" "$2" --overwrite meta.helm.sh/release-name="$RELEASE" meta.helm.sh/release-namespace="$RNS" >/dev/null
  kubectl "${ns[@]}" label "$1" "$2" --overwrite app.kubernetes.io/managed-by=Helm >/dev/null
  echo "adotado: $1/$2 ${3:-}"
}
for p in disallow-root-user disallow-latest-tag require-labels disallow-security-context-optout \
         mutate-security-context generate-default-deny-netpol restrict-image-registries; do
  adotar clusterpolicy "$p"
done
adotar clusterrole auditor-global
adotar clusterrolebinding auditor-global
adotar clusterrolebinding sre-cluster-admin
adotar prometheusrule tipsbank-slo tipsbank-monitoring
adotar configmap dashboard-tipsbank-apis tipsbank-monitoring

# 2. node-agent: o selector muda (ganha a label da release) e selector e imutavel -> recriar
kubectl -n tipsbank-monitoring delete daemonset node-agent --ignore-not-found

# 3. app: namespaces inteiros (Deployments, STS, PVCs, Secrets, NetPols, Ingress...)
kubectl delete namespace $APP_NS --ignore-not-found --wait=true --timeout=5m

# 4. PV estatico da auditoria (VM NFS, Retain): o chart cria o seu com o mesmo nome
kubectl delete pv auditoria-nfs --ignore-not-found

echo "pronto para: helm install $RELEASE <chart> -n $RNS --create-namespace -f values-prod.yaml"
