#!/usr/bin/env bash
# Configura o nfs-kernel-server na tipsbank-nfs (rodar como root na VM).
# all_squash + anonuid/anongid=65532: todo acesso vira o UID 65532 (nonroot do Distroless),
# então os arquivos já nascem com o dono certo e o pod não precisa de initContainer root (chown).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
EXPORT=/srv/nfs/auditoria
CLIENTS=192.168.122.0/24          # só a rede dos nós do cluster

apt-get update -qq && apt-get install -y -qq nfs-kernel-server >/dev/null
mkdir -p $EXPORT
chown 65532:65532 $EXPORT && chmod 0770 $EXPORT
mkdir -p /etc/exports.d
echo "$EXPORT $CLIENTS(rw,sync,no_subtree_check,all_squash,anonuid=65532,anongid=65532)" > /etc/exports.d/tipsbank.exports
exportfs -ra
systemctl enable --now nfs-kernel-server >/dev/null
exportfs -v
