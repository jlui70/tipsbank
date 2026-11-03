# syntax=docker/dockerfile:1.7

# =============================================================================
# Imagem: nginx-unprivileged (roda como user 101, nao-root por default).
# Alternativa didatica a Distroless: enxuta (~25 MB), usuario nao-root,
# binariamente isolada. Dia-13 do DK8s: minimalismo + nao-root.
# =============================================================================
FROM nginxinc/nginx-unprivileged:1.31.7-alpine3.24

# Aplica correcoes de seguranca do Alpine publicadas depois da imagem base
# (zera os HIGH/CRITICAL "fixed" do Trivy). Precisa de root so para isso.
USER root
RUN apk upgrade --no-cache
USER 101

EXPOSE 8080

# Configuracao do nginx (proxy reverso pras APIs)
COPY nginx.conf /etc/nginx/nginx.conf

# Arquivos estaticos do frontend
# Importante: os arquivos na maquina host precisam ter permissao 644 (legivel
# por outros) pro user 101 (nginx) conseguir ler. Docker COPY preserva perms.
COPY html/ /usr/share/nginx/html/
