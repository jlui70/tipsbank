{{/* Partes comuns do primary e da replica */}}
{{- define "tipsbank.postgres.volumesRuntime" -}}
- name: run
  emptyDir: {}
- name: tmp
  emptyDir: {}
{{- end -}}

{{- define "tipsbank.postgres.probes" -}}
readinessProbe:
  exec: {command: [sh, -c, 'pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"']}
  periodSeconds: 5
livenessProbe:
  exec: {command: [sh, -c, 'pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"']}
  initialDelaySeconds: 30
  periodSeconds: 10
{{- end -}}

{{- define "tipsbank.postgres.envSecret" -}}
- name: {{ .nome }}
  valueFrom: {secretKeyRef: {name: postgres-credentials, key: {{ .nome }}}}
{{- end -}}

{{- define "tipsbank.postgres.pvc" -}}
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      {{- with .Values.postgres.storageClassName }}
      storageClassName: {{ . }}
      {{- end }}
      resources:
        requests: {storage: {{ .Values.postgres.armazenamento }}}
{{- end -}}
