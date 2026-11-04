# syntax=docker/dockerfile:1.7

FROM python:3.13-slim-trixie AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir --target=/packages -r requirements.txt

COPY main.py .

FROM gcr.io/distroless/python3-debian13:nonroot

# Etapa 2.4: versão definida no build (docker build --build-arg APP_VERSION=v2 ...).
# O ARG fica no estágio final porque cada FROM começa sem os ARGs anteriores.
ARG APP_VERSION=v1

WORKDIR /app

COPY --from=builder /packages /packages
COPY --from=builder /app/main.py /app/main.py

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/packages \
    PATH=/packages/bin:$PATH \
    APP_VERSION=${APP_VERSION}

EXPOSE 8080

ENTRYPOINT ["python3", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
