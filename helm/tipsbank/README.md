# Chart `tipsbank`

Umbrella do TipsBank (desafio final DK8s 2025): um `helm install` sobe o banco inteiro
(app, banco, NFS, Ingress, autoscaling, NetworkPolicy, RBAC, monitoring e policies)
sobre a plataforma do cluster.

```bash
helm install tipsbank oci://ghcr.io/jlui70/charts/tipsbank --version 1.0.0 \
  -n tipsbank --create-namespace -f values-prod.yaml
```

## Pré-requisitos (plataforma)

O chart traz os **objetos** dos operadores, não os operadores. Instale antes com
[`infra/plataforma/instalar.sh`](../../infra/plataforma/instalar.sh):

| Componente | Para quê |
|---|---|
| StorageClass default (local-path no kubeadm, gp3 no EKS) | PVCs do Postgres e do NFS |
| cert-manager + ClusterIssuer `tipsbank-ca` | TLS dos Ingress (anotação `cert-manager.io/cluster-issuer`) |
| ingress-nginx (IngressClass `nginx`) | Ingress, canary, Basic Auth, rate limit, auth-url |
| kube-prometheus-stack | CRDs ServiceMonitor e PrometheusRule; Grafana carrega o dashboard |
| Kyverno | CRDs ClusterPolicy e PolicyException |
| metrics-server | HPA |

Separar plataforma e app evita o problema de ordem dos CRDs (o Helm não instala um CRD e um objeto
dele na mesma release sem hooks) e garante que `helm uninstall tipsbank` **não** desliga o Kyverno
nem o monitoring do cluster.

## O que o chart cria

| Pasta | Objetos |
|---|---|
| `templates/contas/` | api-contas (Deployment, Service, HPA, ServiceMonitor, SA), Ingress (incl. `/contas/admin` com Basic Auth e bloqueio dos endpoints internos), NetworkPolicies |
| `templates/postgres/` | primary e réplica streaming (StatefulSets + headless), init (SQL de `files/sql/`), Secrets com senhas geradas |
| `templates/transacoes/` | api-transacoes v1 (+ sidecar de log), canary v2 (90/10 + header `X-Canary`), Ingress com cookie de afinidade, NetworkPolicies |
| `templates/auditoria/` | auditoria (PVC RWX no NFS), porteiro (`/eventos` somente leitura), Ingress com hash por `X-Cliente`, NetworkPolicies |
| `templates/web/` | SPA (nginx-unprivileged), Ingress com rate limit, NetworkPolicies |
| `templates/nfs/` | servidor NFSv4 (StatefulSet) + PV + PolicyException, ou só o PV para um NFS externo |
| `templates/loadtest/` | Locust com UI protegida por Basic Auth |
| `templates/monitoring/` | PrometheusRule (4 alertas de SLO), dashboard, DaemonSet node-agent |
| `templates/rbac/` | Roles e bindings dos 4 perfis humanos (certificados: `infra/rbac/gerar-usuario.sh`) |
| `templates/policies/` | 7 ClusterPolicies Kyverno (Validate, Mutate, Generate) |

Helpers (`_helpers.tpl`, `_api.tpl`): `tipsbank.fullname`, `tipsbank.labels`, `tipsbank.labelsDono`,
`tipsbank.imagem` (sempre tag + digest), `tipsbank.senha`, container/Service/HPA/ServiceMonitor das APIs.

## Valores

| Arquivo | Uso |
|---|---|
| `values.yaml` | defaults seguros, comentados |
| `values-prod.yaml` | produção (o lab do desafio): HPA, réplica do banco, canary |
| `values-dev.yaml` | desenvolvimento: 1 réplica, recursos menores, sem réplica do banco, sem canary, sem Locust; `helm uninstall` limpa tudo |
| `values-eks.yaml` | por cima do prod no EKS: domínio real, certificado padrão do controller, rede da VPC, NFS externo (EFS) |

Principais chaves: `global.env` (label `env` de todos os workloads), `global.dominio`,
`<area>.image.{tag,digest}`, `<area>.hpa.*`, `<area>.resources`, `transacoes.canary.*`,
`nfs.modo` (`interno`/`externo`), `rede.*` (IPs do control plane e dos nodes usados nas NetPols),
`policies.failureAction`.

## Segredos

Nenhuma senha no values. Na **primeira** instalação o chart gera as senhas (Postgres admin, replicação,
`app_contas`, `app_transacoes`, Basic Auth); nos `helm upgrade` ele as **reaproveita** (`lookup` do
Secret existente). Para fixar uma senha: `--set postgres.senhas.admin=...`. Como ler: `helm get notes tipsbank -n tipsbank`.

## Uninstall

Em produção (`namespaces.manterNoUninstall: true`) o `helm uninstall` **mantém** os namespaces (e com
eles os dados do Postgres e da auditoria), as ClusterPolicies e o PV da auditoria
(`helm.sh/resource-policy: keep`): dado de banco e controle de segurança não somem por engano.
A limpeza total está no `NOTES.txt`.

## Exceções às próprias policies

| Exceção | Por quê | Escopo |
|---|---|---|
| `nfs-server` (hook pre-install/pre-upgrade) | nfsd de kernel exige root + privileged | só `nfs-server*` no namespace `tipsbank-nfs` |

As exceções dos componentes de plataforma (helper do local-path, ingress-nginx) ficam em
`infra/kyverno/exceptions/`.
