#!/usr/bin/env bash
# Etapa 3.3: cria um worker extra no libvirt/KVM, com a mesma receita do create-vms.sh
# (disco CoW sobre a imagem base, IP fixo por MAC, cloud-init), prepara e faz o join.
# Uso: ./add-worker.sh <nome> <ip> <mac> [memória MiB, padrão 3072]
#   ex.: ./add-worker.sh tipsbank-w3 192.168.122.14 52:54:00:7b:00:14
set -euo pipefail
NAME=${1:?nome}; IP=${2:?ip}; MAC=${3:?mac}; MEM=${4:-3072}
export LIBVIRT_DEFAULT_URI=qemu:///system
POOL=default
BASE=tipsbank-ubuntu-24.04-base.qcow2
CP=192.168.122.10
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
DIR=$(cd "$(dirname "$0")" && pwd)

virsh vol-info --pool $POOL $BASE >/dev/null   # a base da 1.3 precisa existir

# 1) reserva DHCP + disco CoW + cloud-init (igual ao create-vms.sh)
virsh net-update default add ip-dhcp-host \
  "<host mac='$MAC' name='$NAME' ip='$IP'/>" --live --config 2>/dev/null || true
virsh vol-create-as $POOL $NAME.qcow2 30G --format qcow2 \
  --backing-vol $BASE --backing-vol-format qcow2
sed -e "s|__HOSTNAME__|$NAME|" -e "s|__SSH_KEY__|$SSH_KEY|" \
  "$DIR/user-data.tmpl" > "/tmp/user-data-$NAME"
virt-install --name "$NAME" --vcpus 2 --memory "$MEM" \
  --disk vol=$POOL/$NAME.qcow2,bus=virtio \
  --network network=default,mac=$MAC,model=virtio \
  --osinfo ubuntu24.04 --cloud-init user-data="/tmp/user-data-$NAME" \
  --graphics none --noautoconsole --import
rm -f "/tmp/user-data-$NAME"

# 2) espera o SSH e o fim do cloud-init
until ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 ubuntu@$IP true 2>/dev/null; do sleep 5; done
ssh ubuntu@$IP 'cloud-init status --wait >/dev/null'

# 3) prepara o nó (containerd, kubeadm, kubelet...) e faz o join
ssh ubuntu@$IP 'sudo bash -s' < "$DIR/prepare-node.sh"
JOIN=$(ssh ubuntu@$CP 'kubeadm token create --print-join-command')
ssh ubuntu@$IP "sudo $JOIN"
echo "OK: $NAME ($IP) entrou no cluster"
