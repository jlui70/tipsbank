#!/usr/bin/env bash
# Gera o Secret da Basic Auth de /contas/admin a partir do template *.example (etapa 2.2).
# O secret-basic-auth.yaml e a senha em texto (.basic-auth-senha) ficam no .gitignore.
#
# Uso:
#   ./k8s/contas/gerar-basic-auth.sh                  # senha aleatória (ou reaproveita a já gerada)
#   ADMIN_PASS='minha-senha' ./k8s/contas/gerar-basic-auth.sh
#   ADMIN_USER=operador ./k8s/contas/gerar-basic-auth.sh   # usuário (padrão: admin)
#   ./k8s/contas/gerar-basic-auth.sh --force          # gera senha NOVA
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$DIR/secret-basic-auth.yaml
SENHA_ARQ=$DIR/.basic-auth-senha
USUARIO=${ADMIN_USER:-admin}

if [[ -z "${ADMIN_PASS:-}" && "${1:-}" != "--force" && -f "$SENHA_ARQ" ]]; then
  ADMIN_PASS=$(cat "$SENHA_ARQ")
  echo "reaproveitando a senha existente em ${SENHA_ARQ#$DIR/}"
fi
ADMIN_PASS=${ADMIN_PASS:-$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)}

# -stdin: a senha não aparece na linha de comando (ps, histórico)
HASH=$(printf '%s' "$ADMIN_PASS" | openssl passwd -6 -stdin)

umask 077                                  # arquivos novos só para o dono (600)
printf '%s\n' "$ADMIN_PASS" > "$SENHA_ARQ"
sed -e "s|__USUARIO__|$USUARIO|" -e "s|__HASH__|$HASH|" "$OUT.example" > "$OUT"
echo "gerado: ${OUT#$DIR/} (usuário: $USUARIO, senha em ${SENHA_ARQ#$DIR/})"
