{{/* =====================================================================
     Blocos comuns das APIs (contas, transacoes v1/v2, auditoria)
     ===================================================================== */}}

{{/* Container "app" (o nome e fixo: o HPA ContainerResource da 3.7 referencia "app").
     Uso: include "tipsbank.api.container" (dict "root" $ "cfg" .Values.contas "img" .Values.contas.image
          "env" (list ...) "args" (list ...) "volumeMounts" (list ...)) */}}
{{- define "tipsbank.api.container" -}}
{{- $p := .root.Values.apiPadrao -}}
- name: app
  image: {{ include "tipsbank.imagem" (dict "root" .root "img" .img) }}
  imagePullPolicy: {{ .root.Values.global.imagePullPolicy }}
  {{- with .args }}
  args: {{ toYaml . | nindent 4 }}
  {{- end }}
  ports:
    - {name: http, containerPort: 8080}
  {{- with .env }}
  env: {{ toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- include "tipsbank.containerSecurityContext" (dict "uid" $p.uid) | nindent 4 }}
  lifecycle:
    preStop:
      sleep: {seconds: {{ $p.preStopSegundos }}}
  startupProbe:
    httpGet: {path: /health/startup, port: http}
    {{- toYaml $p.probes.startup | nindent 4 }}
  readinessProbe:
    httpGet: {path: /health/ready, port: http}
    {{- toYaml $p.probes.readiness | nindent 4 }}
  livenessProbe:
    httpGet: {path: /health/live, port: http}
    {{- toYaml $p.probes.liveness | nindent 4 }}
  resources:
    {{- toYaml (default $p.resources .cfg.resources) | nindent 4 }}
  {{- with .volumeMounts }}
  volumeMounts: {{ toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}

{{/* Service ClusterIP da API (porta 8080 "http"). tipsbank.io/job vira o job no Prometheus.
     Uso: include "tipsbank.api.service" (dict "root" $ "ns" ... "nome" ... "componente" ... "job" ... "seletor" (dict ...)) */}}
{{- define "tipsbank.api.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .nome }}
  namespace: {{ .ns }}
  labels:
    {{- include "tipsbank.labels" (dict "root" .root "componente" .componente) | nindent 4 }}
    tipsbank.io/job: {{ .job }}
    {{- with .labelsExtras }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  type: ClusterIP
  selector:
    {{- toYaml .seletor | nindent 4 }}
  ports:
    - {name: http, port: 8080, targetPort: http}
{{- end -}}

{{/* HPA (3.7). metrica: cpu | cpu-container (ContainerResource do container "app") | memory */}}
{{- define "tipsbank.api.hpa" -}}
{{- if .cfg.hpa.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .nome }}
  namespace: {{ .ns }}
  labels:
    {{- include "tipsbank.labels" (dict "root" .root "componente" .nome) | nindent 4 }}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: {{ .nome }}}
  minReplicas: {{ .cfg.hpa.minReplicas }}
  maxReplicas: {{ .cfg.hpa.maxReplicas }}
  metrics:
    {{- if eq .cfg.hpa.metrica "cpu-container" }}
    - type: ContainerResource
      containerResource:
        name: cpu
        container: app
        target: {type: Utilization, averageUtilization: {{ .cfg.hpa.alvo }}}
    {{- else if eq .cfg.hpa.metrica "memory" }}
    - type: Resource
      resource:
        name: memory
        target: {type: Utilization, averageUtilization: {{ .cfg.hpa.alvo }}}
    {{- else }}
    - type: Resource
      resource:
        name: cpu
        target: {type: Utilization, averageUtilization: {{ .cfg.hpa.alvo }}}
    {{- end }}
  behavior:
    {{- toYaml .root.Values.apiPadrao.hpaComportamento | nindent 4 }}
{{- end }}
{{- end -}}

{{/* ServiceMonitor (3.5): coleta /metrics; jobLabel = label tipsbank.io/job do Service */}}
{{- define "tipsbank.api.servicemonitor" -}}
{{- if .root.Values.monitoring.serviceMonitors }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ .nome }}
  namespace: {{ .ns }}
  labels:
    {{- include "tipsbank.labels" (dict "root" .root "componente" .nome) | nindent 4 }}
spec:
  jobLabel: tipsbank.io/job
  selector:
    matchLabels:
      tipsbank.io/job: {{ .job }}
  {{- with .podTargetLabels }}
  podTargetLabels: {{ toYaml . | nindent 4 }}
  {{- end }}
  endpoints:
    - {port: http, path: /metrics, interval: 15s}
{{- end }}
{{- end -}}

{{/* ServiceAccount sem token (4.4) */}}
{{- define "tipsbank.serviceaccount" -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .nome }}
  namespace: {{ .ns }}
  labels:
    {{- include "tipsbank.labels" (dict "root" .root "componente" .nome) | nindent 4 }}
automountServiceAccountToken: false
{{- end -}}

{{/* Anti-affinity preferida (3.3): espalha as replicas por nodes */}}
{{- define "tipsbank.antiAffinity" -}}
podAntiAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector: {matchLabels: {app.kubernetes.io/name: {{ .componente }}}}
        topologyKey: kubernetes.io/hostname
{{- end -}}

{{/* Ingress de API nos 2 hosts: api.<dominio>/<prefixo>/... e app.<dominio>/api/<prefixo>/...
     Uso: include "tipsbank.api.ingress" (dict "root" $ "ns" ... "nome" ... "servico" ... "prefixo" "contas"
          "anotacoes" (dict ...) "anotacoesApi" (dict ...)) */}}
{{- define "tipsbank.api.ingress" -}}
{{- $d := .root.Values.global.dominio -}}
{{- range $h := list (dict "sufixo" "" "host" (printf "api.%s" $d) "path" (printf "/%s(/|$)(.*)" $.prefixo) "tls" "api-tipsbank-tls" "extras" $.anotacoesApi)
                     (dict "sufixo" "-spa" "host" (printf "app.%s" $d) "path" (printf "/api/%s(/|$)(.*)" $.prefixo) "tls" "app-tipsbank-tls" "extras" dict) }}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $.nome }}{{ $h.sufixo }}
  namespace: {{ $.ns }}
  labels:
    {{- include "tipsbank.labels" (dict "root" $.root "componente" $.servico) | nindent 4 }}
  annotations:
    {{- include "tipsbank.ingressTlsAnotacoes" $.root | nindent 4 }}
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    {{- with $.anotacoes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- with $h.extras }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  ingressClassName: {{ $.root.Values.global.ingressClassName }}
  tls:
    - hosts: [{{ $h.host }}]
      {{- if $.root.Values.global.tlsSecretPorHost }}
      secretName: {{ $h.tls }}
      {{- end }}
  rules:
    - host: {{ $h.host }}
      http:
        paths:
          - path: {{ $h.path }}
            pathType: ImplementationSpecific
            backend: {service: {name: {{ $.servico }}, port: {number: 8080}}}
{{- end }}
{{- end -}}
