#!/usr/bin/env bash
# Etapa 3.7 — certificado de SERVIDOR do kubelet assinado pela CA do cluster (pré-requisito do Metrics Server).
#
# No kubeadm, o kubelet serve a porta 10250 com um certificado AUTOASSINADO (/var/lib/kubelet/pki/kubelet.crt).
# O Metrics Server (e o kubectl logs/exec, via API server) falam HTTPS com essa porta: sem uma CA em comum, a
# saída fácil é --kubelet-insecure-tls (não confere nada). Aqui fazemos o certo:
#   1. serverTLSBootstrap: true no ConfigMap kubelet-config (vale para os próximos "kubeadm join") e no
#      /var/lib/kubelet/config.yaml de cada node (vale já), com restart do kubelet, um node por vez;
#   2. cada kubelet pede um certificado por CSR (signer kubernetes.io/kubelet-serving);
#   3. o script APROVA só o CSR que bate com o node: requisitante system:node:<nome>, e DNS/IP dos SANs =
#      nome e InternalIP do node. Esse signer NÃO é aprovado automaticamente pelo kube-controller-manager.
#
# A renovação (rotateCertificates: true, ~1 ano) gera CSR novo: rode este script de novo para aprová-lo.
#
# Uso: KUBECONFIG=... ./infra/kubeadm/kubelet-serving-tls.sh            (todos os nodes)
#      KUBECONFIG=... ./infra/kubeadm/kubelet-serving-tls.sh --approve  (só aprovar CSRs pendentes)
set -euo pipefail
SSH_USER=${SSH_USER:-ubuntu}

aprovar_csrs() {
  local tentativas=${1:-12}
  for _ in $(seq "$tentativas"); do
    local pendentes
    pendentes=$(kubectl get csr -o json | python3 -c '
import json, sys
for c in json.load(sys.stdin)["items"]:
    if c["spec"].get("signerName") != "kubernetes.io/kubelet-serving": continue
    if c.get("status", {}).get("conditions"): continue          # já aprovado/negado
    print(c["metadata"]["name"], c["spec"]["username"])')
    [[ -z "$pendentes" ]] && { sleep 5; continue; }
    while read -r csr usuario; do
      local node=${usuario#system:node:}
      local ip; ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
      # SANs pedidos no CSR (decodifica o PEM com openssl)
      local sans; sans=$(kubectl get csr "$csr" -o jsonpath='{.spec.request}' | base64 -d \
        | openssl req -noout -text | grep -A1 'Subject Alternative Name' | tail -1 | tr -d ' ')
      if [[ "$usuario" == system:node:* && "$sans" == "DNS:$node,IPAddress:$ip" ]]; then
        kubectl certificate approve "$csr" >/dev/null
        echo "aprovado: $csr ($node: $sans)"
      else
        echo "NÃO aprovado: $csr de $usuario com SANs '$sans' (esperado DNS:$node,IPAddress:$ip)" >&2
      fi
    done <<<"$pendentes"
    return 0
  done
}

if [[ "${1:-}" == "--approve" ]]; then aprovar_csrs 12; exit 0; fi   # espera até 60 s pelo CSR

# 1. ConfigMap do kubeadm (para os próximos joins)
cm=$(kubectl -n kube-system get cm kubelet-config -o jsonpath='{.data.kubelet}')
if ! grep -q '^serverTLSBootstrap: true' <<<"$cm"; then
  novo=$(sed 's/^rotateCertificates: true$/rotateCertificates: true\nserverTLSBootstrap: true/' <<<"$cm")
  kubectl -n kube-system patch cm kubelet-config --type=merge \
    -p "$(python3 -c 'import json,sys; print(json.dumps({"data":{"kubelet":sys.argv[1]}}))' "$novo")" >/dev/null
  echo "ConfigMap kube-system/kubelet-config: serverTLSBootstrap: true"
fi

# 2. Cada node, um por vez
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  ssh -o BatchMode=yes "$SSH_USER@$ip" 'sudo bash -s' <<'EOF'
set -e
f=/var/lib/kubelet/config.yaml
if grep -q '^serverTLSBootstrap: true' $f; then echo "  já configurado"; exit 0; fi
cp -p $f $f.antes-3.7
sed -i 's/^rotateCertificates: true$/rotateCertificates: true\nserverTLSBootstrap: true/' $f
systemctl restart kubelet
echo "  kubelet reiniciado"
EOF
  echo "$node ($ip): ok"
  aprovar_csrs
  # espera o node voltar a Ready antes do próximo
  kubectl wait --for=condition=Ready "node/$node" --timeout=120s >/dev/null
done

echo
kubectl get csr --sort-by=.metadata.creationTimestamp | grep -E 'NAME|kubelet-serving' | tail -6
