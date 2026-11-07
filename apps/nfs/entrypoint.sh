#!/bin/sh
# Sobe um servidor NFSv4 (so TCP 2049) e para de forma limpa no SIGTERM.
# Espera:
#   /etc/exports      montado de ConfigMap (somente leitura)
#   $EXPORT_DIR       volume persistente (PVC) exportado
#   /var/lib/nfs, /run  emptyDir (estado do nfsd/mountd; a raiz e read-only)
set -eu
EXPORT_DIR=${EXPORT_DIR:-/exports}
ANON_UID=${ANON_UID:-65532}

[ -s /etc/exports ] || { echo "ERRO: /etc/exports vazio (monte o ConfigMap)"; exit 1; }
# all_squash: todo cliente grava como $ANON_UID; o diretorio exportado e dele.
chown "$ANON_UID:$ANON_UID" "$EXPORT_DIR"
chmod 0750 "$EXPORT_DIR"
mkdir -p /var/lib/nfs/v4recovery /run

parar() {
  echo "parando NFS"
  rpc.nfsd 0 || true
  exportfs -au || true
  exportfs -f || true
  [ -n "${MOUNTD_PID:-}" ] && kill "$MOUNTD_PID" 2>/dev/null || true
  umount /proc/fs/nfsd 2>/dev/null || true
  exit 0
}
trap parar TERM INT

mount -t nfsd nfsd /proc/fs/nfsd
exportfs -ra
# so NFSv4: sem v3, sem UDP -> nao precisa de rpcbind nem de portas extras.
# (v2 nao e citado: o kernel dos nodes ja nao tem NFSv2 e "--no-nfs-version 2" falha com
#  "2: Unsupported version" - achado no 1o deploy, v1.0.0)
rpc.mountd --no-nfs-version 3 --nfs-version 4 --no-udp --foreground &
MOUNTD_PID=$!
rpc.nfsd --grace-time 10 --no-nfs-version 3 --nfs-version 4 --no-udp 8
echo "NFSv4 pronto:"
exportfs -v

while :; do sleep 5 & wait $! || true; done
