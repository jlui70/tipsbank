{{/* Pod da api-transacoes, comum a v1 e v2 (canary). Parametros: root, versao, img, cfg */}}
{{- define "tipsbank.transacoes.pod" -}}
{{- $t := .root.Values.transacoes -}}
{{- $env := list (dict "name" "DB_URL" "valueFrom" (dict "secretKeyRef" (dict "name" "transacoes-db" "key" "DB_URL"))) -}}
{{- range $k, $_ := $t.config -}}
{{- if or (ne $k "APP_VERSION") (eq $.versao "v1") -}}
{{- /* 2.4: a v2 nao recebe APP_VERSION do ConfigMap (a imagem v2 ja informa a propria versao) */ -}}
{{- $env = append $env (dict "name" $k "valueFrom" (dict "configMapKeyRef" (dict "name" "transacoes-config" "key" $k))) -}}
{{- end -}}
{{- end -}}
{{- range list "CONTAS_URL" "AUDITORIA_URL" -}}
{{- $env = append $env (dict "name" . "valueFrom" (dict "configMapKeyRef" (dict "name" "transacoes-config" "key" .))) -}}
{{- end -}}
metadata:
  labels:
    {{- include "tipsbank.labels" (dict "root" .root "componente" "api-transacoes") | nindent 4 }}
    role: app
    version: {{ .versao }}
  annotations:
    checksum/config: {{ printf "%s%s" (toYaml $t.config) (.root.Files.Get "files/transacoes-log-config.json") | sha256sum | trunc 12 }}
spec:
  serviceAccountName: api-transacoes
  automountServiceAccountToken: false
  securityContext:
    {{- include "tipsbank.podSecurityContext" (dict "uid" .root.Values.apiPadrao.uid "fsGroup" true) | nindent 4 }}
  affinity:
    {{- include "tipsbank.antiAffinity" (dict "componente" "api-transacoes") | nindent 4 }}
  containers:
    {{- include "tipsbank.api.container" (dict "root" .root "cfg" $t "img" .img "env" $env
          "args" (list "--log-config" "/etc/app/log-config.json")
          "volumeMounts" (list (dict "name" "app-logs" "mountPath" "/var/log/app") (dict "name" "log-config" "mountPath" "/etc/app" "readOnly" true))) | nindent 4 }}
    # 1.5: sidecar que encaminha o arquivo de log da app para o stdout
    - name: log-forwarder
      image: {{ include "tipsbank.imagem" (dict "root" .root "img" $t.logForwarder.image) }}
      imagePullPolicy: {{ .root.Values.global.imagePullPolicy }}
      # tail como PID 1 ignora o SIGTERM (o kernel nao entrega sinal sem handler ao PID 1) e o pod
      # esperava os 30 s do terminationGracePeriod em todo rollout. O sh com trap encerra na hora.
      command: [sh, -c, 'trap "exit 0" TERM INT; tail -n +1 -F /var/log/app/app.log & wait $!']
      securityContext:
        {{- include "tipsbank.containerSecurityContext" (dict "uid" .root.Values.apiPadrao.uid) | nindent 8 }}
      livenessProbe:
        exec: {command: [pidof, tail]}
        periodSeconds: 30
      resources:
        {{- toYaml $t.logForwarder.resources | nindent 8 }}
      volumeMounts:
        - {name: app-logs, mountPath: /var/log/app, readOnly: true}
  volumes:
    - name: app-logs
      emptyDir: {sizeLimit: 50Mi}
    - name: log-config
      configMap: {name: transacoes-log-config}
{{- end -}}
