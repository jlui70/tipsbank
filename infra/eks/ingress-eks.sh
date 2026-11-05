#!/usr/bin/env bash
# Gera os Ingress do EKS a partir dos mesmos arquivos do kubeadm (etapa 2.3) e imprime na tela.
# Uso:  ./infra/eks/ingress-eks.sh | kubectl apply -f -
#       ./infra/eks/ingress-eks.sh | less          (para revisar antes)
#
# 3 trocas, só no texto que sai (os arquivos do repositório não mudam):
#   1. hosts *.tipsbank.local -> *.tipsbank.devopsproject.com.br (DNS real);
#   2. sai a anotação do ClusterIssuer da CA do lab (no EKS o certificado é um só, do Let's Encrypt);
#   3. sai o secretName dos blocos tls: o controller usa o certificado padrão (--default-ssl-certificate).
# Na 4.5 (Helm) essas diferenças viram values (values-kubeadm x values-eks), sem sed.
set -euo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
DOMINIO=${DOMINIO:-tipsbank.devopsproject.com.br}

# Trava: estes Ingress são só para o EKS. Aplicados no kubeadm, trocariam os hosts do lab.
CTX=$(kubectl config current-context 2>/dev/null || true)
if [[ "$CTX" != "eks-tipsbank" && -z "${FORCAR:-}" ]]; then
  echo "ERRO: context atual é '$CTX', não 'eks-tipsbank'. Use: kubectl config use-context eks-tipsbank" >&2
  echo "      (para só gerar o YAML sem aplicar, rode com FORCAR=1)" >&2
  exit 1
fi

for f in web/ingress.yaml contas/ingress.yaml transacoes/ingress.yaml auditoria/ingress.yaml ${CANARY:+transacoes/ingress-canary.yaml}; do
  echo "---"
  sed -e "s/\.tipsbank\.local/.$DOMINIO/g" \
      -e '/cert-manager.io\/cluster-issuer: tipsbank-ca/d' \
      -e '/secretName: .*-tipsbank-tls/d' \
      "$DIR/k8s/$f"
done
