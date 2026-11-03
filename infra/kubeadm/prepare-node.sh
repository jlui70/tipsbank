#!/usr/bin/env bash
# Prepara um nó para o kubeadm (rodar como root em TODOS os nós).
# Referência: Day-5 + https://kubernetes.io/docs/setup/production-environment/
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
K8S_MINOR=v1.36
K8S_VERSION=1.36.6-1.1

# 1) swap desligada (kubelet recusa subir com swap por padrão)
swapoff -a
sed -i '/\sswap\s/ s/^/#/' /etc/fstab

# 2) módulos do kernel: overlay (containerd) e br_netfilter (iptables enxergar tráfego de bridge)
cat > /etc/modules-load.d/k8s.conf <<M
overlay
br_netfilter
M
modprobe overlay && modprobe br_netfilter

# 3) sysctl: roteamento IPv4 e bridge passando pelo iptables
cat > /etc/sysctl.d/k8s.conf <<S
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
S
sysctl --system >/dev/null

# 4) containerd 2.x (repo oficial do Docker; o K8s 1.36 não suporta mais containerd 1.x)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq && apt-get install -y -qq containerd.io >/dev/null

# config padrão + cgroup driver systemd (tem que bater com o kubelet)
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || { echo "SystemdCgroup não encontrado"; exit 1; }
systemctl restart containerd && systemctl enable containerd >/dev/null
cat > /etc/crictl.yaml <<C
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
C

# 5) kubeadm, kubelet, kubectl (repo pkgs.k8s.io) travados na versão
curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet=$K8S_VERSION kubeadm=$K8S_VERSION kubectl=$K8S_VERSION >/dev/null
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable kubelet >/dev/null

# 6) cliente NFS: o kubelet usa mount.nfs do NÓ para montar PVs NFS (etapa 1.6)
apt-get install -y -qq nfs-common >/dev/null

echo "== $(hostname): $(containerd --version | awk '{print $3}') | $(kubeadm version -o short) | swap: $(swapon --show | wc -l) linhas"
