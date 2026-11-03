#!/usr/bin/env bash
# Cria as 3 VMs (1 control-plane + 2 workers) no libvirt/KVM.
# Uso: ./create-vms.sh /caminho/ubuntu-24.04-server-cloudimg-amd64.img
set -euo pipefail
IMG=${1:?informe o caminho da cloud image do Ubuntu 24.04}
export LIBVIRT_DEFAULT_URI=qemu:///system
POOL=default
BASE=tipsbank-ubuntu-24.04-base.qcow2
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
DIR=$(cd "$(dirname "$0")" && pwd)

# nome  ip              mac
NODES="tipsbank-cp 192.168.122.10 52:54:00:7b:00:10
tipsbank-w1 192.168.122.11 52:54:00:7b:00:11
tipsbank-w2 192.168.122.12 52:54:00:7b:00:12"

# 1) imagem base no pool (somente leitura, usada como backing file)
if ! virsh vol-info --pool $POOL $BASE &>/dev/null; then
  virsh vol-create-as $POOL $BASE "$(stat -c %s "$IMG")" --format qcow2
  virsh vol-upload --pool $POOL $BASE "$IMG"
fi

while read -r NAME IP MAC; do
  # 2) reserva DHCP: IP fixo por MAC na rede default
  virsh net-update default add ip-dhcp-host \
    "<host mac='$MAC' name='$NAME' ip='$IP'/>" --live --config 2>/dev/null || true

  # 3) disco de 30G em copy-on-write sobre a base
  virsh vol-create-as $POOL $NAME.qcow2 30G --format qcow2 \
    --backing-vol $BASE --backing-vol-format qcow2

  # 4) user-data do cloud-init
  sed -e "s|__HOSTNAME__|$NAME|" -e "s|__SSH_KEY__|$SSH_KEY|" \
    "$DIR/user-data.tmpl" > "/tmp/user-data-$NAME"

  # 5) VM: 2 vCPU / 4 GiB, sem swap (cloud image não cria swap)
  virt-install --name "$NAME" --vcpus 2 --memory 4096 \
    --disk vol=$POOL/$NAME.qcow2,bus=virtio \
    --network network=default,mac=$MAC,model=virtio \
    --osinfo ubuntu24.04 --cloud-init user-data="/tmp/user-data-$NAME" \
    --graphics none --noautoconsole --import
  rm -f "/tmp/user-data-$NAME"
done <<< "$NODES"

virsh list
