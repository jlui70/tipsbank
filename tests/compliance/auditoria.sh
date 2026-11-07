#!/usr/bin/env bash
# TipsBank - etapa 4.6: checklist de compliance "auditoria BACEN".
# Parte A: os 7 comandos do MANUAL-ALUNO, sem alteracao (so "seuuser" -> jlui70).
# Parte B: checagens extras que um auditor faria (o manual nao pede):
#   B1  comando #2 restrito aos namespaces de aplicacao (kube-system = plataforma)
#   B2  #1 tambem nos initContainers + toda imagem pinada por digest
#   B3  #7 com identidade ESTRITA (o '.*' do manual aceita qualquer assinante) em
#       TODAS as imagens proprias em execucao, pelo digest que esta rodando
#   B4  imagens do kubeadm (so por tag): assinatura oficial do Kubernetes
#   B5  PolicyExceptions vigentes (toda excecao precisa estar listada e justificada)
#   B6  3 manifests ruins (tests/compliance/ruim-*.yaml) -> todos recusados
# Uso: KUBECONFIG=... tests/compliance/auditoria.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
USR=jlui70
ID=188764035+jlui70@users.noreply.github.com
ISSUER=https://github.com/login/oauth
t() { printf '\n### %s\n' "$*"; }

t "#1 Nenhuma imagem fora do registry confiavel"
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | grep -v "ghcr.io/$USR\|quay.io/jetstack\|registry.k8s.io\|gcr.io/distroless"
echo "(fim #1)"

t "#2 Nenhum pod rodando como root"
kubectl get pods -A -o json | jq '[.items[] | select(.spec.securityContext.runAsUser == 0 or (.spec.containers[].securityContext.runAsUser // 0) == 0) | .metadata.name]'

t "#3 Cobertura de probes"
kubectl get deploy,sts,ds -A -o json | jq '[.items[] | select(.spec.template.spec.containers[].livenessProbe == null) | .metadata.name]'

t "#4 Cobertura de resources"
kubectl get deploy,sts,ds -A -o json | jq '[.items[] | select(.spec.template.spec.containers[].resources.limits == null) | .metadata.name]'

t "#5 Policies Kyverno ativas (status.ready do manual + condicao Ready do Kyverno 1.19)"
kubectl get cpol -o json 2>/dev/null | jq -c '.items[] | {name: .metadata.name, ready: .status.ready, Ready: ((.status.conditions // [])[] | select(.type=="Ready") | .status)}'

t "#6 NetworkPolicies nos namespaces tipsbank-*"
for ns in tipsbank-contas tipsbank-transacoes tipsbank-auditoria; do
  echo "\$ kubectl get netpol -n $ns"; kubectl get netpol -n "$ns"
done

t "#7 Imagens assinadas (Cosign) - comando do manual"
for img in ghcr.io/$USR/tipsbank-api-contas:v1.0.0 ghcr.io/$USR/tipsbank-api-transacoes:v1.0.0 ghcr.io/$USR/tipsbank-auditoria:v1.0.0; do
  cosign verify "$img" --certificate-identity-regexp '.*' --certificate-oidc-issuer-regexp '.*' >/dev/null 2>&1 && echo "OK: $img" || echo "FALHA: $img"
done

t "B1 #2 nos namespaces de aplicacao (fora kube-system)"
kubectl get pods -A -o json | jq -c '[.items[] | select(.metadata.namespace != "kube-system") | select(.spec.securityContext.runAsUser == 0 or (.spec.containers[].securityContext.runAsUser // 0) == 0) | .metadata.namespace + "/" + .metadata.name]'

t "B2 initContainers fora do registry confiavel / imagens sem digest"
IMGS=$(kubectl get pods -A -o json | jq -r '[.items[].spec | (.containers + (.initContainers // []))[] | .image] | unique[]')
echo "total de imagens distintas: $(wc -l <<<"$IMGS")"
echo "fora do registry confiavel:"; grep -v "^ghcr.io/$USR/\|^quay.io/jetstack/\|^registry.k8s.io/\|^gcr.io/distroless/" <<<"$IMGS" || echo "  (nenhuma)"
echo "sem digest (so tag):"; grep -v '@sha256:' <<<"$IMGS" || echo "  (nenhuma)"

t "B3 Cosign ESTRITO (identidade $ID) em todas as imagens proprias em execucao"
for img in $(grep "^ghcr.io/$USR/tipsbank-" <<<"$IMGS"); do
  cosign verify "$img" --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" >/dev/null 2>&1 && echo "OK: $img" || echo "FALHA: $img"
done

t "B4 Imagens do kubeadm (so tag): assinatura oficial do projeto Kubernetes"
for img in $(grep -v '@sha256:' <<<"$IMGS"); do
  cosign verify "$img" --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
    --certificate-oidc-issuer https://accounts.google.com >/dev/null 2>&1 && echo "OK: $img" || echo "FALHA: $img"
done

t "B5 PolicyExceptions vigentes"
kubectl get policyexception -A -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): " + ([.spec.exceptions[] | .policyName + "[" + (.ruleNames | join(",")) + "]"] | join(" "))'

t "B6 Manifests ruins (devem ser TODOS recusados)"
for f in "$DIR"/ruim-*.yaml; do
  echo "\$ kubectl apply -f tests/compliance/$(basename "$f")"
  if kubectl apply -f "$f" 2>&1; then echo "!!! ACEITO (falha de compliance)"; kubectl delete -f "$f" --wait=false; else echo "=> RECUSADO"; fi
done
