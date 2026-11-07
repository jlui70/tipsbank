#!/usr/bin/env bash
# Espelha as imagens de terceiros de imagens.txt em ghcr.io/<usuario>/mirror/... (etapa 4.3).
#
# Uso (no terminal do usuario, ja logado no ghcr com permissao de escrita):
#   docker login ghcr.io -u jlui70
#   ./infra/mirror/espelhar-imagens.sh            # copia (pula as que ja estao certas)
#   ./infra/mirror/espelhar-imagens.sh --conferir # so confere (leitura anonima + digest)
#
# `docker buildx imagetools create --prefer-index=false` copia o manifest registry a
# registry, sem baixar para o disco e sem rebuild: o digest no destino e o mesmo.
# 429 (limite do ghcr: 2000 req/min) -> espera e tenta de novo.
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
DESTINO=${DESTINO:-ghcr.io/jlui70/mirror}
MODO=${1:-copiar}

destino_de() {             # docker.io/library/busybox:1.37 -> ghcr.io/jlui70/mirror/busybox:1.37
  local caminho=${1#*/}
  caminho=${caminho#library/}
  echo "$DESTINO/$caminho"
}
digest_em() {              # digest publicado no destino ("" se nao existe/sem acesso)
  docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest // empty'
}

falhas=0
while read -r src indice amd64; do
  [[ -z "$src" || "$src" == \#* ]] && continue
  dst=$(destino_de "$src")
  if [[ "$MODO" == "--conferir" ]]; then
    # leitura ANONIMA (como o kubelet vai puxar): DOCKER_CONFIG vazio = sem credencial
    got=$(DOCKER_CONFIG=$(mktemp -d) digest_em "$dst")
    if [[ "$got" == "$amd64" ]]; then echo "OK      $dst@$amd64"
    elif [[ -z "$got" ]]; then echo "PRIVADO/AUSENTE $dst"; falhas=$((falhas+1))
    else echo "DIGEST DIFERENTE $dst ($got)"; falhas=$((falhas+1)); fi
    continue
  fi
  if [[ "$(digest_em "$dst")" == "$amd64" ]]; then echo "ja ok   $dst"; continue; fi
  for tentativa in 1 2 3 4 5; do
    echo ">> [$tentativa] ${src%:*}@$amd64 -> $dst"
    if docker buildx imagetools create --prefer-index=false --tag "$dst" "${src%:*}@$amd64"; then
      break
    fi
    espera=$((tentativa * 20)); echo "   falhou; nova tentativa em ${espera}s"; sleep "$espera"
  done
  [[ "$(digest_em "$dst")" == "$amd64" ]] || { echo "FALHOU  $dst"; falhas=$((falhas+1)); }
  sleep 3                                   # alivia o limite de requisicoes do ghcr
done < "$DIR/imagens.txt"
echo "falhas: $falhas"
[[ "$MODO" == "--conferir" ]] || echo "Confira a leitura anonima com: $0 --conferir"
exit $(( falhas > 0 ))
