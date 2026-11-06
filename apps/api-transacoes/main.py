"""
TipsBank — API de Transacoes
Transferencias entre contas. Chama api-contas e publica eventos em auditoria.
"""
import os
import logging
import time
import uuid
from contextlib import asynccontextmanager
from decimal import Decimal

import httpx
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, Field
from sqlalchemy import Column, String, Numeric, DateTime, create_engine, func
from sqlalchemy.orm import declarative_base, sessionmaker, Session
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","service":"api-transacoes","msg":"%(message)s"}',
)
log = logging.getLogger("api-transacoes")

DB_URL = os.getenv(
    "DB_URL",
    "postgresql+psycopg://tipsbank:tipsbank@postgres:5432/tipsbank",
)
CONTAS_URL = os.getenv("CONTAS_URL", "http://api-contas:8080")
AUDITORIA_URL = os.getenv("AUDITORIA_URL", "http://auditoria:8080")
APP_VERSION = os.getenv("APP_VERSION", "v1")

# v1.2.0 (etapa 3.7): pool configurável. Com HPA, o total de conexões no Postgres é
#   réplicas máximas x (DB_POOL_SIZE + DB_MAX_OVERFLOW)  e precisa caber em max_connections.
# Com o fixo 5+10 e 25 pods no stress test, o Postgres (max_connections=100) recusou conexões
# ("too many clients"). Pool cheio = a requisição ESPERA uma conexão (até DB_POOL_TIMEOUT), não falha.
engine = create_engine(
    DB_URL,
    pool_pre_ping=True,
    pool_size=int(os.getenv("DB_POOL_SIZE", "5")),
    max_overflow=int(os.getenv("DB_MAX_OVERFLOW", "10")),
    pool_timeout=float(os.getenv("DB_POOL_TIMEOUT", "30")),
)

# v1.1.0 (etapa 3.7): UM cliente HTTP para o processo todo (thread-safe), com keep-alive.
# Antes, cada chamada criava um httpx.Client(): ~25 ms de CPU por construção (carrega o bundle de CAs do
# certifi) e uma conexão TCP nova. Com 2 clientes por transferência, ~1/3 da CPU dos workers ia nisso.
HTTP = httpx.Client(timeout=5.0, limits=httpx.Limits(max_connections=50, max_keepalive_connections=20))
TENTATIVAS_CONTAS = 2   # repetir é seguro: a api-contas é idempotente por tx_id
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False)
Base = declarative_base()


class Transacao(Base):
    __tablename__ = "transacoes"
    id = Column(String, primary_key=True)
    origem_id = Column(String, nullable=False, index=True)
    destino_id = Column(String, nullable=False, index=True)
    valor = Column(Numeric(15, 2), nullable=False)
    status = Column(String, nullable=False)
    criada_em = Column(DateTime, server_default=func.now())


class TransferenciaIn(BaseModel):
    origem_id: str
    destino_id: str
    valor: Decimal = Field(gt=0)


class TransacaoOut(BaseModel):
    id: str
    origem_id: str
    destino_id: str
    valor: Decimal
    status: str

    class Config:
        from_attributes = True


req_counter = Counter("http_requests_total", "Total de requisições HTTP", ["method", "path", "status"])
req_latency = Histogram("http_request_duration_seconds", "Latência", ["path"])
tx_counter = Counter("transacoes_total", "Transacoes executadas", ["status"])


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info(f"bootstrap versao={APP_VERSION}")
    Base.metadata.create_all(engine)
    yield
    HTTP.close()


app = FastAPI(title="TipsBank — Transacoes", lifespan=lifespan)


@app.middleware("http")
async def obs(request, call_next):
    # v1.1.0 (achado da 3.6): exceção não tratada também conta como 500 na métrica (finally)
    start = time.time()
    status = 500
    try:
        resp = await call_next(request)
        status = resp.status_code
        resp.headers["X-App-Version"] = APP_VERSION
        return resp
    finally:
        req_counter.labels(request.method, request.url.path, status).inc()
        req_latency.labels(request.url.path).observe(time.time() - start)


def db() -> Session:
    return SessionLocal()


@app.get("/health/live")
async def live():
    # v1.1.0 (etapa 3.7): async = fora do pool de threads das rotas síncronas (não espera thread livre)
    return {"status": "ok", "version": APP_VERSION}


@app.get("/health/ready")
def ready():
    try:
        s = SessionLocal()
        s.execute(func.now().select()).scalar()
        s.close()
        return {"status": "ready"}
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


@app.get("/health/startup")
def startup():
    return {"status": "started"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/pix")
def pix():
    # Etapa 2.4: endpoint novo da v2 (mock), usado para mostrar o canary. Na imagem v1.0.0 é 404.
    return {"status": "mock", "pix": "em breve", "version": APP_VERSION}


@app.post("/transferencias", response_model=TransacaoOut, status_code=201)
def transferir(payload: TransferenciaIn):
    """v1.1.0 (etapa 3.7): débito + crédito numa chamada só, atômica e idempotente, na api-contas.

    Antes eram 2 chamadas /saldo: se a 1ª desse timeout depois de o débito ser gravado, o dinheiro saía e
    não chegava; se a 2ª desse timeout depois do crédito, o "estorno" duplicava o valor. No stress test
    da 3.7 isso deixou R$ 6.480,20 divergentes. Agora o tx_id gerado aqui é a chave de idempotência:
    repetir a chamada nunca move o dinheiro duas vezes.
    """
    tx_id = str(uuid.uuid4())
    log.info(f"transferencia id={tx_id} origem={payload.origem_id} destino={payload.destino_id} valor={payload.valor}")
    s = db()
    try:
        # v1.2.0: registra a INTENÇÃO antes de mover o dinheiro. Se este INSERT falhar, nada foi movido.
        # Antes o registro vinha depois: no stress test, 112 movimentos ficaram sem transação (o INSERT
        # falhou por falta de conexão DEPOIS de a api-contas já ter transferido).
        tx = Transacao(id=tx_id, origem_id=payload.origem_id, destino_id=payload.destino_id,
                       valor=payload.valor, status="pendente")
        s.add(tx)
        s.commit()

        corpo = {"tx_id": tx_id, "origem_id": payload.origem_id,
                 "destino_id": payload.destino_id, "valor": str(payload.valor)}
        r = None
        for tentativa in range(1, TENTATIVAS_CONTAS + 1):
            try:
                r = HTTP.post(f"{CONTAS_URL}/transferencias-internas", json=corpo)
                break
            except httpx.TransportError as e:          # timeout, conexão recusada/cortada
                log.warning(f"api-contas falhou tx_id={tx_id} tentativa={tentativa}: {e!r}")

        if r is None:
            # resultado DESCONHECIDO (o pedido pode ter sido gravado antes do timeout): fica "pendente";
            # a conciliação compara com o ledger movimentos da api-contas pelo mesmo tx_id
            tx_counter.labels("pendente").inc()
            raise HTTPException(status_code=503, detail=f"api-contas indisponivel; transacao {tx_id} pendente")
        if r.status_code in (404, 422):
            tx.status = "recusada"
            s.commit()
            tx_counter.labels("recusada").inc()
            raise HTTPException(status_code=r.status_code, detail=r.json().get("detail", r.text))
        if r.status_code != 200:
            # a transferência na api-contas é atômica: resposta de erro = nada foi movido
            tx.status = "falha"
            s.commit()
            tx_counter.labels("falha_contas").inc()
            raise HTTPException(status_code=502, detail=f"api-contas respondeu {r.status_code}")

        tx.status = "concluida"
        s.commit()
        s.refresh(tx)

        try:
            HTTP.post(
                f"{AUDITORIA_URL}/eventos",
                timeout=3.0,
                json={
                    "tipo": "transferencia",
                    "transacao_id": tx.id,
                    "origem_id": tx.origem_id,
                    "destino_id": tx.destino_id,
                    "valor": str(tx.valor),
                    "versao_app": APP_VERSION,
                },
            )
        except Exception as e:
            log.warning(f"auditoria indisponivel: {e}")

        tx_counter.labels("ok").inc()
        return tx
    finally:
        s.close()


@app.get("/transferencias/{tx_id}", response_model=TransacaoOut)
def obter(tx_id: str):
    s = db()
    try:
        tx = s.query(Transacao).get(tx_id)
        if not tx:
            raise HTTPException(status_code=404, detail="nao encontrada")
        return tx
    finally:
        s.close()


@app.get("/extrato/{conta_id}", response_model=list[TransacaoOut])
def extrato(conta_id: str, limit: int = 20):
    s = db()
    try:
        from sqlalchemy import or_
        q = (
            s.query(Transacao)
            .filter(or_(Transacao.origem_id == conta_id, Transacao.destino_id == conta_id))
            .order_by(Transacao.criada_em.desc())
            .limit(min(limit, 100))
        )
        return q.all()
    finally:
        s.close()
