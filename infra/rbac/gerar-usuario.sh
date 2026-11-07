#!/usr/bin/env bash
# Gera chave + CSR + certificado assinado pela CA do cluster + kubeconfig de um usuario (etapa 4.4).
#
# Uso: ./infra/rbac/gerar-usuario.sh <usuario> <arquivo-kubeconfig> [dias]
#   ex.: ./infra/rbac/gerar-usuario.sh operador-contas op-contas 30
# Saida em evidencias/kubeconfigs/ (no .gitignore: a chave privada vai DENTRO do kubeconfig).
#
# Fluxo (Day-18): openssl gera a chave e o CSR -> objeto CertificateSigningRequest com
# signerName kubernetes.io/kube-apiserver-client -> aprovacao por um admin -> o
# kube-controller-manager assina com a CA do cluster -> kubeconfig com cert + chave.
# Roda com o kubeconfig de admin (quem aprova o CSR).
set -euo pipefail
USUARIO=${1:?usuario (CN)}; ARQ=${2:?nome do kubeconfig}; DIAS=${3:-30}
RAIZ=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$RAIZ/evidencias/kubeconfigs"; mkdir -p "$OUT"; umask 077
KEY="$OUT/$ARQ.key"; CSR="$OUT/$ARQ.csr"; CRT="$OUT/$ARQ.crt"; KCFG="$OUT/$ARQ.kubeconfig"

# 1. chave ECDSA P-256 e CSR. CN = usuario. Sem O= (grupo): permissoes so via binding.
openssl ecparam -name prime256v1 -genkey -noout -out "$KEY"
openssl req -new -key "$KEY" -subj "/CN=$USUARIO" -out "$CSR"

# 2. CSR no cluster, validade curta
kubectl delete csr "$USUARIO" --ignore-not-found >/dev/null
cat <<YAML | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $USUARIO
  labels: {team: plataforma, tipsbank.io/perfil: $USUARIO}
spec:
  request: $(base64 -w0 < "$CSR")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $((DIAS * 86400))
  usages: [client auth]
YAML

# 3. aprovacao (quatro olhos: num banco, quem pede nao aprova) e certificado emitido
kubectl certificate approve "$USUARIO"
for i in $(seq 30); do
  c=$(kubectl get csr "$USUARIO" -o jsonpath='{.status.certificate}'); [[ -n "$c" ]] && break; sleep 1
done
echo "$c" | base64 -d > "$CRT"
openssl x509 -in "$CRT" -noout -subject -issuer -enddate

# 4. kubeconfig proprio (CA do cluster + cert + chave embutidos)
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
rm -f "$KCFG"
KUBECONFIG="$KCFG" kubectl config set-cluster tipsbank-kubeadm --server="$SERVER" >/dev/null
KUBECONFIG="$KCFG" kubectl config set clusters.tipsbank-kubeadm.certificate-authority-data "$CA" >/dev/null
KUBECONFIG="$KCFG" kubectl config set-credentials "$USUARIO" --client-certificate="$CRT" --client-key="$KEY" --embed-certs=true >/dev/null
KUBECONFIG="$KCFG" kubectl config set-context "$USUARIO@tipsbank" --cluster=tipsbank-kubeadm --user="$USUARIO" >/dev/null
KUBECONFIG="$KCFG" kubectl config use-context "$USUARIO@tipsbank" >/dev/null
rm -f "$CSR"
echo "kubeconfig: $KCFG"
