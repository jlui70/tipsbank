{{/* =====================================================================
     Helpers do chart tipsbank (Day-19: define/include, nindent, toYaml, default)
     ===================================================================== */}}

{{/* Nome do chart (respeita nameOverride) */}}
{{- define "tipsbank.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Nome completo da release (respeita fullnameOverride) */}}
{{- define "tipsbank.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains (include "tipsbank.name" .) .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "tipsbank.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* chart-versao (label helm.sh/chart) */}}
{{- define "tipsbank.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels comuns de TODO objeto do chart.
     Uso: include "tipsbank.labels" (dict "root" $ "componente" "api-contas") */}}
{{- define "tipsbank.labels" -}}
helm.sh/chart: {{ include "tipsbank.chart" .root }}
app.kubernetes.io/name: {{ .componente }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: tipsbank
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
{{- end -}}

{{/* Labels de DONO, exigidas pela policy require-labels em Deployment/StatefulSet/DaemonSet.
     Uso: include "tipsbank.labelsDono" (dict "root" $ "app" "api-contas" "team" "contas") */}}
{{- define "tipsbank.labelsDono" -}}
app: {{ .app }}
team: {{ .team }}
env: {{ .root.Values.global.env }}
{{- end -}}

{{/* Selector estavel (NAO muda entre versoes: selector de Deployment e imutavel) */}}
{{- define "tipsbank.selector" -}}
app.kubernetes.io/name: {{ .componente }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{/* Imagem sempre com tag E digest (policy disallow-latest-tag + rastreabilidade).
     Uso: include "tipsbank.imagem" (dict "root" $ "img" .Values.contas.image) */}}
{{- define "tipsbank.imagem" -}}
{{- $repo := printf "%s/%s" .root.Values.global.registry .img.repository -}}
{{- $tag := required (printf "tag obrigatoria para %s" .img.repository) .img.tag -}}
{{- if .img.digest -}}
{{- printf "%s:%s@%s" $repo $tag .img.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
{{- end -}}

{{/* Senha gerada UMA vez por instalacao e reaproveitada:
     1. valor passado por --set (fixo)            -> usa
     2. Secret ja existe no cluster (upgrade)     -> reaproveita (lookup)
     3. senao                                      -> gera 24 caracteres
     O cache em .Values.__senhas garante o MESMO valor em todos os templates da mesma
     renderizacao (ex.: postgres-credentials e o DB_URL da api-transacoes).
     Uso: include "tipsbank.senha" (dict "root" $ "ns" "tipsbank-contas" "secret" "postgres-credentials" "chave" "POSTGRES_PASSWORD" "fixa" .Values.postgres.senhas.admin) */}}
{{- define "tipsbank.senha" -}}
{{- if not (hasKey .root.Values "__senhas") -}}
{{- $_ := set .root.Values "__senhas" dict -}}
{{- end -}}
{{- $cache := index .root.Values "__senhas" -}}
{{- $id := printf "%s/%s/%s" .ns .secret .chave -}}
{{- if not (hasKey $cache $id) -}}
  {{- $valor := "" -}}
  {{- if .fixa -}}
    {{- $valor = .fixa -}}
  {{- else -}}
    {{- $existente := lookup "v1" "Secret" .ns .secret -}}
    {{- if and $existente $existente.data (hasKey $existente.data .chave) -}}
      {{- $valor = index $existente.data .chave | b64dec -}}
    {{- else -}}
      {{- $valor = randAlphaNum 24 -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $cache $id $valor -}}
{{- end -}}
{{- index $cache $id -}}
{{- end -}}

{{/* Anotacoes de TLS do Ingress (cert-manager), se houver ClusterIssuer */}}
{{- define "tipsbank.ingressTlsAnotacoes" -}}
{{- with .Values.global.clusterIssuer }}
cert-manager.io/cluster-issuer: {{ . }}
{{- end }}
{{- end -}}

{{/* securityContext de pod nao-root (uid informado) */}}
{{- define "tipsbank.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ .uid }}
{{- if .fsGroup }}
fsGroup: {{ .uid }}
{{- end }}
seccompProfile: {type: RuntimeDefault}
{{- end -}}

{{/* securityContext de container endurecido. runAsUser repetido no container: o comando #2
     da auditoria (4.6) so olha o nivel do container. */}}
{{- define "tipsbank.containerSecurityContext" -}}
runAsUser: {{ .uid }}
runAsNonRoot: true
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities: {drop: [ALL]}
{{- end -}}

{{/* NetworkPolicies base de todo namespace (2.5): default-deny + DNS */}}
{{- define "tipsbank.netpolBase" -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: {{ .ns }}
  labels:
    {{- include "tipsbank.labels" (dict "root" .root "componente" "networkpolicy") | nindent 4 }}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: {{ .ns }}
  labels:
    {{- include "tipsbank.labels" (dict "root" .root "componente" "networkpolicy") | nindent 4 }}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
          podSelector: {matchLabels: {k8s-app: kube-dns}}
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
{{- end -}}

{{/* "from" de um pod em outro namespace (NetPol) */}}
{{- define "tipsbank.de" -}}
- namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: {{ .ns }}}}
  podSelector: {matchLabels: {app.kubernetes.io/name: {{ .app }}}}
{{- end -}}
