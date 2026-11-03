#!/usr/bin/env bash
# Gera os Secrets do Postgres a partir dos templates *.example.
# Os secret-db.yaml gerados ficam no .gitignore: a senha nunca vai para o Git.
#
# Uso:
#   ./k8s/gerar-secrets.sh            # gera senha aleatória (ou reaproveita a já gerada)
#   PG_PASS='minha-senha' ./k8s/gerar-secrets.sh   # usa a senha informada
#   ./k8s/gerar-secrets.sh --force    # gera senha NOVA (cuidado: o Postgres já inicializado
#                                     # continua com a senha antiga gravada no PVC)
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
CONTAS=$DIR/contas/secret-db.yaml
TRANS=$DIR/transacoes/secret-db.yaml

if [[ -z "${PG_PASS:-}" && "${1:-}" != "--force" && -f "$CONTAS" ]]; then
  # reaproveita a senha já gerada (o banco foi inicializado com ela)
  PG_PASS=$(grep 'POSTGRES_PASSWORD:' "$CONTAS" | cut -d'"' -f2)
  echo "reaproveitando a senha existente em $CONTAS"
fi
# 20 caracteres alfanuméricos: sem / + = para não quebrar a DB_URL
PG_PASS=${PG_PASS:-$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)}

for f in "$CONTAS" "$TRANS"; do
  sed "s|__POSTGRES_PASSWORD__|$PG_PASS|g" "$f.example" > "$f"
  chmod 600 "$f"
  echo "gerado: ${f#$DIR/}"
done
