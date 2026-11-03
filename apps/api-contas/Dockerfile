# syntax=docker/dockerfile:1.7

# =============================================================================
# STAGE 1 — builder (Python 3.13-slim, Debian 13 trixie)
# =============================================================================
FROM python:3.13-slim-trixie AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir --target=/packages -r requirements.txt

COPY main.py .

# =============================================================================
# STAGE 2 — runtime (Distroless Python, sem shell, sem package manager)
# gcr.io/distroless/python3-debian13 → Python 3.13 + glibc, user nonroot (uid 65532)
# =============================================================================
FROM gcr.io/distroless/python3-debian13:nonroot

WORKDIR /app

COPY --from=builder /packages /packages
COPY --from=builder /app/main.py /app/main.py

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/packages \
    PATH=/packages/bin:$PATH

EXPOSE 8080

ENTRYPOINT ["python3", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
