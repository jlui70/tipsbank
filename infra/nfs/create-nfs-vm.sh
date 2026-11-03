#!/usr/bin/env bash
# Cria a VM tipsbank-nfs (servidor NFS FORA do cluster) reaproveitando a imagem base
# e o cloud-init da etapa 1.3. Pré-requisito: infra/kubeadm/create-vms.sh já rodou (imagem base no pool).
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system
POOL=default
BASE=tipsbank-ubuntu-24.04-base.qcow2
NAME=tipsbank-nfs IP=192.168.122.13 MAC=52:54:00:7b:00:13
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
TMPL=$(cd "$(dirname "$0")/../kubeadm" && pwd)/user-data.tmpl

virsh vol-info --pool $POOL $BASE >/dev/null   # falha cedo se a base não existir
virsh net-update default add ip-dhcp-host "<host mac='$MAC' name='$NAME' ip='$IP'/>" --live --config 2>/dev/null || true
virsh vol-create-as $POOL $NAME.qcow2 20G --format qcow2 --backing-vol $BASE --backing-vol-format qcow2
sed -e "s|__HOSTNAME__|$NAME|" -e "s|__SSH_KEY__|$SSH_KEY|" "$TMPL" > /tmp/user-data-$NAME
virt-install --name $NAME --vcpus 1 --memory 1024 \
  --disk vol=$POOL/$NAME.qcow2,bus=virtio \
  --network network=default,mac=$MAC,model=virtio \
  --osinfo ubuntu24.04 --cloud-init user-data=/tmp/user-data-$NAME \
  --graphics none --noautoconsole --import
rm -f /tmp/user-data-$NAME
