"""
TipsBank — API de Contas
Gerencia contas bancárias: criação, consulta, saldo e autenticação.
"""
import os
import logging
from contextlib import asynccontextmanager
from decimal import Decimal
from typing import Optional

import bcrypt
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, Field
from sqlalchemy import Column, String, Numeric, DateTime, create_engine, func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import declarative_base, sessionmaker, Session
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
import time
import uuid

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","service":"api-contas","msg":"%(message)s"}',
)
log = logging.getLogger("api-contas")

DB_URL = os.getenv(
    "DB_URL",
    "postgresql+psycopg://tipsbank:tipsbank@postgres:5432/tipsbank",
)
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
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False)
Base = declarative_base()


class Conta(Base):
    __tablename__ = "contas"
    id = Column(String, primary_key=True)
    titular = Column(String, nullable=False)
    documento = Column(String, nullable=False, unique=True)
    senha_hash = Column(String, nullable=False, default="")
    saldo = Column(Numeric(15, 2), nullable=False, default=0)
    criada_em = Column(DateTime, server_default=func.now())


class Movimento(Base):
    """v1.1.0 (etapa 3.7): ledger das transferências. tx_id é a chave de idempotência.

    Débito, crédito e o registro daqui entram na MESMA transação SQL: ou os três acontecem, ou nenhum.
    Se a api-transacoes repetir o pedido (timeout, pod reiniciado), o tx_id já existe e nada é movido de novo.
    """
    __tablename__ = "movimentos"
    tx_id = Column(String(64), primary_key=True)
    origem_id = Column(String(64), nullable=False)
    destino_id = Column(String(64), nullable=False)
    valor = Column(Numeric(15, 2), nullable=False)
    criada_em = Column(DateTime, server_default=func.now())


class ContaIn(BaseModel):
    titular: str = Field(min_length=3, max_length=120)
    documento: str = Field(min_length=11, max_length=14)
    senha: str = Field(min_length=4, max_length=72)
    saldo_inicial: Decimal = Field(default=Decimal("0"), ge=0)


class ContaOut(BaseModel):
    id: str
    titular: str
    documento: str
    saldo: Decimal

    class Config:
        from_attributes = True


class LoginIn(BaseModel):
    documento: str = Field(min_length=11, max_length=14)
    senha: str = Field(min_length=1, max_length=72)


class TransferenciaInterna(BaseModel):
    tx_id: str = Field(min_length=1, max_length=64)
    origem_id: str
    destino_id: str
    valor: Decimal = Field(gt=0)


class TransferenciaInternaOut(BaseModel):
    tx_id: str
    origem_id: str
    destino_id: str
    valor: Decimal
    repetida: bool = False      # True = tx_id já processado antes (resposta idempotente, nada foi movido agora)


class AjusteSaldo(BaseModel):
    valor: Decimal
    operacao: str = Field(pattern="^(credito|debito)$")


def hash_senha(senha: str) -> str:
    return bcrypt.hashpw(senha.encode("utf-8"), bcrypt.gensalt(rounds=10)).decode("utf-8")


def senha_confere(senha: str, senha_hash: str) -> bool:
    if not senha_hash:
        return False
    try:
        return bcrypt.checkpw(senha.encode("utf-8"), senha_hash.encode("utf-8"))
    except Exception:
        return False


login_counter = Counter("tipsbank_login_total", "Tentativas de login", ["status"])


req_counter = Counter("http_requests_total", "Total de requisições HTTP", ["method", "path", "status"])
req_latency = Histogram("http_request_duration_seconds", "Latência das requisições", ["path"])


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("bootstrap: criando schema se necessário")
    Base.metadata.create_all(engine)
    yield
    log.info("shutdown")


app = FastAPI(title="TipsBank — Contas", lifespan=lifespan)


@app.middleware("http")
async def observabilidade(request, call_next):
    # v1.1.0 (achado da 3.6): uma exceção não tratada sobe pelo call_next e, antes, pulava o .inc():
    # a API devolvia 500 (gerado pelo Starlette) sem contar na métrica. Agora o 500 é contado no finally.
    start = time.time()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        req_counter.labels(request.method, request.url.path, status).inc()
        req_latency.labels(request.url.path).observe(time.time() - start)


def db() -> Session:
    s = SessionLocal()
    try:
        return s
    except Exception:
        s.close()
        raise


@app.get("/health/live")
async def live():
    # v1.1.0 (etapa 3.7): async = roda no event loop, fora do pool de threads das rotas síncronas.
    # Com "def", sob carga a liveness esperava thread livre, passava do timeout e o kubelet matava o pod.
    return {"status": "ok"}


@app.get("/health/ready")
def ready():
    try:
        s = SessionLocal()
        s.execute(func.now().select()).scalar()
        s.close()
        return {"status": "ready"}
    except Exception as e:
        log.error(f"readiness falhou: {e}")
        raise HTTPException(status_code=503, detail="db indisponivel")


@app.get("/health/startup")
def startup():
    return {"status": "started"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/contas", response_model=ContaOut, status_code=201)
def criar_conta(payload: ContaIn):
    s = db()
    try:
        existente = s.query(Conta).filter_by(documento=payload.documento).first()
        if existente:
            raise HTTPException(status_code=409, detail="documento ja cadastrado")
        nova = Conta(
            id=str(uuid.uuid4()),
            titular=payload.titular,
            documento=payload.documento,
            senha_hash=hash_senha(payload.senha),
            saldo=payload.saldo_inicial,
        )
        s.add(nova)
        s.commit()
        s.refresh(nova)
        log.info(f"conta criada id={nova.id} titular={nova.titular}")
        return nova
    finally:
        s.close()


@app.post("/login", response_model=ContaOut)
def login(payload: LoginIn):
    s = db()
    try:
        # tolera CPF com pontuacao no input
        doc_limpo = "".join(ch for ch in payload.documento if ch.isdigit())
        conta = s.query(Conta).filter_by(documento=doc_limpo).first()
        if not conta or not senha_confere(payload.senha, conta.senha_hash or ""):
            login_counter.labels("falhou").inc()
            log.warning(f"login falhou doc={doc_limpo[:3]}***")
            raise HTTPException(status_code=401, detail="credenciais invalidas")
        login_counter.labels("ok").inc()
        log.info(f"login ok titular={conta.titular}")
        return conta
    finally:
        s.close()


@app.get("/contas", response_model=list[ContaOut])
def listar_contas(limit: int = 50):
    s = db()
    try:
        return s.query(Conta).limit(min(limit, 200)).all()
    finally:
        s.close()


@app.get("/contas/{conta_id}", response_model=ContaOut)
def obter_conta(conta_id: str):
    s = db()
    try:
        c = s.query(Conta).get(conta_id)
        if not c:
            raise HTTPException(status_code=404, detail="conta nao encontrada")
        return c
    finally:
        s.close()


@app.post("/contas/{conta_id}/saldo", response_model=ContaOut)
def ajustar_saldo(conta_id: str, payload: AjusteSaldo):
    s = db()
    try:
        c = s.query(Conta).with_for_update().filter_by(id=conta_id).first()
        if not c:
            raise HTTPException(status_code=404, detail="conta nao encontrada")
        if payload.operacao == "credito":
            c.saldo = c.saldo + payload.valor
        else:
            if c.saldo < payload.valor:
                raise HTTPException(status_code=422, detail="saldo insuficiente")
            c.saldo = c.saldo - payload.valor
        s.commit()
        s.refresh(c)
        return c
    finally:
        s.close()


@app.post("/transferencias-internas", response_model=TransferenciaInternaOut)
def transferir_interno(payload: TransferenciaInterna):
    """v1.1.0 (etapa 3.7): transferência ATÔMICA e IDEMPOTENTE, chamada pela api-transacoes.

    Substitui as duas chamadas /saldo (débito e depois crédito), que sob timeout deixavam dinheiro pela
    metade (no stress test da 3.7: R$ 6.480,20 divergentes em 151 de 200 contas). /saldo continua existindo
    para clientes antigos (canary v2.0.0).
    """
    if payload.origem_id == payload.destino_id:
        raise HTTPException(status_code=422, detail="origem e destino iguais")
    s = db()
    try:
        anterior = s.get(Movimento, payload.tx_id)
        if anterior:
            return TransferenciaInternaOut(tx_id=anterior.tx_id, origem_id=anterior.origem_id,
                                           destino_id=anterior.destino_id, valor=anterior.valor, repetida=True)
        # trava as duas contas sempre na mesma ordem (por id): duas transferências cruzadas A->B e B->A
        # não ficam esperando uma pela outra (deadlock)
        contas = {
            c.id: c
            for c in s.query(Conta).filter(Conta.id.in_([payload.origem_id, payload.destino_id]))
                                   .order_by(Conta.id).with_for_update().all()
        }
        origem, destino = contas.get(payload.origem_id), contas.get(payload.destino_id)
        if not origem or not destino:
            raise HTTPException(status_code=404, detail="conta nao encontrada")
        if origem.saldo < payload.valor:
            raise HTTPException(status_code=422, detail="saldo insuficiente")
        origem.saldo = origem.saldo - payload.valor
        destino.saldo = destino.saldo + payload.valor
        s.add(Movimento(tx_id=payload.tx_id, origem_id=payload.origem_id,
                        destino_id=payload.destino_id, valor=payload.valor))
        try:
            s.commit()
        except IntegrityError:
            # o mesmo tx_id chegou em paralelo e o outro commit ganhou: nada foi movido por este
            s.rollback()
            anterior = s.get(Movimento, payload.tx_id)
            return TransferenciaInternaOut(tx_id=anterior.tx_id, origem_id=anterior.origem_id,
                                           destino_id=anterior.destino_id, valor=anterior.valor, repetida=True)
        log.info(f"transferencia interna tx_id={payload.tx_id} valor={payload.valor}")
        return TransferenciaInternaOut(tx_id=payload.tx_id, origem_id=payload.origem_id,
                                       destino_id=payload.destino_id, valor=payload.valor)
    finally:
        s.close()
