{{/* Cabecalho comum das ClusterPolicies */}}
{{- define "tipsbank.policy.meta" -}}
metadata:
  name: {{ .nome }}
  labels:
    {{- include "tipsbank.labels" (dict "root" .root "componente" "kyverno-policy") | nindent 4 }}
  annotations:
    {{- if .root.Values.policies.manterNoUninstall }}
    helm.sh/resource-policy: keep        # helm uninstall do app nao desliga a seguranca do cluster
    {{- end }}
    policies.kyverno.io/title: {{ .titulo | quote }}
    policies.kyverno.io/category: TipsBank Compliance
    policies.kyverno.io/severity: {{ default "high" .severidade }}
    policies.kyverno.io/subject: {{ default "Pod" .assunto }}
    {{- with .extras }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
{{- end -}}

{{/* match/exclude padrao: Pods em CREATE/UPDATE (no DELETE o CEL quebra e o Enforce negaria, 4.1) */}}
{{- define "tipsbank.policy.matchPod" -}}
match:
  any:
    - resources:
        kinds: {{ default (list "Pod") .kinds | toJson }}
        operations: {{ default (list "CREATE" "UPDATE") .operacoes | toJson }}
exclude:
  any:
    - resources:
        namespaces: {{ .root.Values.policies.namespacesExcluidos | toJson }}
{{- end -}}

{{/* failureAction + override Audit (kube-system) */}}
{{- define "tipsbank.policy.acao" -}}
failureAction: {{ .Values.policies.failureAction }}
{{- with .Values.policies.namespacesAudit }}
failureActionOverrides:
  - action: Audit
    namespaces: {{ toJson . }}
{{- end }}
{{- end -}}

{{/* lista de todos os containers (CEL) */}}
{{- define "tipsbank.policy.celContainers" -}}
- name: containers
  expression: >-
    object.spec.containers
    + object.spec.?initContainers.orValue([])
    + object.spec.?ephemeralContainers.orValue([])
{{- end -}}
