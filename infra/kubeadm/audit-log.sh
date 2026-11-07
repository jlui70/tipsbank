#!/usr/bin/env bash
# Liga o audit log do kube-apiserver no control-plane kubeadm (complemento da etapa 4.4).
#
# - Copia infra/kubeadm/audit-policy.yaml para /etc/kubernetes/audit/policy.yaml no cp.
# - Edita o manifest estatico /etc/kubernetes/manifests/kube-apiserver.yaml (o kubelet
#   reinicia o API server sozinho): flags --audit-* + 2 volumes hostPath.
#   Log em /var/log/kubernetes/audit/audit.log, rotacao 100 MB x 10 arquivos, 30 dias.
# - Grava o mesmo no ConfigMap kubeadm-config (ClusterConfiguration), para um
#   `kubeadm upgrade` nao apagar a configuracao.
# - Backup do manifest em /root/ no cp; se o API server nao voltar em 3 min, restaura.
# Durante o restart do API server (~30-60 s) o kubectl fica indisponivel; os pods e o
# trafego da aplicacao NAO dependem dele.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
CP=${CP:-ubuntu@192.168.122.10}
STAMP=$(date +%Y%m%d-%H%M%S)

scp -q "$DIR/audit-policy.yaml" "$CP:/tmp/audit-policy.yaml"
ssh "$CP" "sudo install -d -m 0700 /etc/kubernetes/audit /var/log/kubernetes/audit && \
  sudo install -m 0600 /tmp/audit-policy.yaml /etc/kubernetes/audit/policy.yaml && rm /tmp/audit-policy.yaml && \
  sudo cp -p /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak-$STAMP"

ssh "$CP" "sudo python3 -" <<'PY'
import yaml
p = '/etc/kubernetes/manifests/kube-apiserver.yaml'
m = yaml.safe_load(open(p))
c = m['spec']['containers'][0]
flags = {
    '--audit-policy-file': '/etc/kubernetes/audit/policy.yaml',
    '--audit-log-path': '/var/log/kubernetes/audit/audit.log',
    '--audit-log-maxage': '30',
    '--audit-log-maxbackup': '10',
    '--audit-log-maxsize': '100',
}
cmd = [a for a in c['command'] if a.split('=')[0] not in flags]
cmd += [f'{k}={v}' for k, v in flags.items()]
c['command'] = cmd
mounts = [v for v in c.get('volumeMounts', []) if v['name'] not in ('audit-policy', 'audit-log')]
mounts += [{'name': 'audit-policy', 'mountPath': '/etc/kubernetes/audit/policy.yaml', 'readOnly': True},
           {'name': 'audit-log', 'mountPath': '/var/log/kubernetes/audit'}]
c['volumeMounts'] = mounts
vols = [v for v in m['spec'].get('volumes', []) if v['name'] not in ('audit-policy', 'audit-log')]
vols += [{'name': 'audit-policy', 'hostPath': {'path': '/etc/kubernetes/audit/policy.yaml', 'type': 'File'}},
         {'name': 'audit-log', 'hostPath': {'path': '/var/log/kubernetes/audit', 'type': 'DirectoryOrCreate'}}]
m['spec']['volumes'] = vols
tmp = '/root/kube-apiserver.yaml.novo'
yaml.safe_dump(m, open(tmp, 'w'), default_flow_style=False, sort_keys=False)
import os; os.replace(tmp, p)        # troca atomica: o kubelet nunca le arquivo pela metade
print('manifest atualizado')
PY

echo "aguardando o API server voltar..."
sleep 15
for i in $(seq 36); do
  if kubectl get --raw /readyz >/dev/null 2>&1; then echo "API server pronto"; break; fi
  if [[ $i == 36 ]]; then
    echo "API server NAO voltou: restaurando o backup"
    ssh "$CP" "sudo cp -p /root/kube-apiserver.yaml.bak-$STAMP /etc/kubernetes/manifests/kube-apiserver.yaml"
    exit 1
  fi
  sleep 5
done

# persistencia para o kubeadm upgrade (ClusterConfiguration v1beta4: extraArgs e lista)
kubectl -n kube-system get cm kubeadm-config -o json | python3 -c '
import json, sys, yaml
cm = json.load(sys.stdin)
cc = yaml.safe_load(cm["data"]["ClusterConfiguration"])
api = cc.setdefault("apiServer", {}) or {}
cc["apiServer"] = api
args = [a for a in api.get("extraArgs", []) if not a["name"].startswith("audit-")]
args += [{"name": "audit-policy-file", "value": "/etc/kubernetes/audit/policy.yaml"},
         {"name": "audit-log-path", "value": "/var/log/kubernetes/audit/audit.log"},
         {"name": "audit-log-maxage", "value": "30"},
         {"name": "audit-log-maxbackup", "value": "10"},
         {"name": "audit-log-maxsize", "value": "100"}]
api["extraArgs"] = args
vols = [v for v in api.get("extraVolumes", []) if v["name"] not in ("audit-policy", "audit-log")]
vols += [{"name": "audit-policy", "hostPath": "/etc/kubernetes/audit/policy.yaml", "mountPath": "/etc/kubernetes/audit/policy.yaml", "readOnly": True, "pathType": "File"},
         {"name": "audit-log", "hostPath": "/var/log/kubernetes/audit", "mountPath": "/var/log/kubernetes/audit", "pathType": "DirectoryOrCreate"}]
api["extraVolumes"] = vols
cm["data"]["ClusterConfiguration"] = yaml.safe_dump(cc, sort_keys=False)
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields"): cm["metadata"].pop(k, None)
json.dump(cm, sys.stdout)
' | kubectl apply -f - >/dev/null && echo "kubeadm-config atualizado"
ssh "$CP" "sudo tail -n 1 /var/log/kubernetes/audit/audit.log | cut -c1-200"
