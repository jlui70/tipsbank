#!/usr/bin/env bash
# Gera infra/monitoring/secrets.yaml (Grafana + Basic Auth do Prometheus/Alertmanager) a partir do *.example.
# secrets.yaml e .senhas ficam no .gitignore. Reaproveita as senhas já geradas; --force gera novas.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$DIR/secrets.yaml
SENHAS=$DIR/.senhas
gera() { openssl rand -base64 18 | tr -d '/+=' | cut -c1-16; }

if [[ "${1:-}" != "--force" && -f "$SENHAS" ]]; then
  # shellcheck disable=SC1090
  source "$SENHAS"; echo "reaproveitando as senhas de ${SENHAS#$DIR/}"
fi
GRAFANA_PASS=${GRAFANA_PASS:-$(gera)}
MON_PASS=${MON_PASS:-$(gera)}
HASH=$(printf '%s' "$MON_PASS" | openssl passwd -6 -stdin)   # -stdin: senha fora da linha de comando

umask 077
printf 'GRAFANA_PASS=%s\nMON_PASS=%s\n' "$GRAFANA_PASS" "$MON_PASS" > "$SENHAS"
sed -e "s|__GRAFANA_PASS__|$GRAFANA_PASS|" -e "s|__HASH__|$HASH|" "$OUT.example" > "$OUT"
echo "gerado: ${OUT#$DIR/} (usuário admin nos dois; senhas em ${SENHAS#$DIR/}: GRAFANA_PASS e MON_PASS)"
