# Servidor NFS v4 do TipsBank (etapa 4.5, templates/nfs/ do Helm umbrella).
# Substitui a imagem de teste registry.k8s.io/e2e-test-images/volume/nfs:1.4
# (CentOS 7 sem suporte, 81 HIGH/CRITICAL corrigiveis no Trivy, export no_root_squash).
#
# - Alpine + nfs-utils, so NFSv4 (sem rpcbind, porta unica 2049/TCP).
# - /etc/exports NAO e gravado pela imagem: vem de um ConfigMap (root filesystem read-only).
# - O servidor NFS de kernel exige root + privileged (mount do nfsd). Isso e uma
#   PolicyException nominal no chart (namespace tipsbank-nfs, nfs-server-*).
FROM alpine:3.23@sha256:f3d55900449227ae9e237ede521e7b665d53a253b42065ba90b9db9275e198ad
RUN apk upgrade --no-cache && apk add --no-cache nfs-utils
COPY --chmod=0555 entrypoint.sh /usr/local/bin/entrypoint.sh
EXPOSE 2049/tcp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
