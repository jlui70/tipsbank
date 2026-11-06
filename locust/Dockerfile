# Etapa 3.7 — imagem do Locust do TipsBank (Deployment em k8s/loadtest/locust.yaml).
# Base oficial fixada por digest (2.31.3, a versão do repositório de referência). Roda como o usuário
# "locust" (uid 1000) da própria imagem. Publicada como ghcr.io/jlui70/tipsbank-locust (assinada com cosign).
FROM locustio/locust:2.31.3@sha256:4611a67bd86839c3040d22e568b5a95ddc03a016fd26a5bf2abb44c44ea609ad
COPY locustfile.py /mnt/locust/locustfile.py
USER 1000:1000
ENTRYPOINT ["locust", "-f", "/mnt/locust/locustfile.py"]
