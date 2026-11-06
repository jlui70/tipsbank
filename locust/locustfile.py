"""
Locust - stress test do TipsBank.
Simula usuarios criando contas e fazendo transferencias.

Etapa 3.7 (correcoes do arquivo de referencia):
- a conta e criada na api-contas (CONTAS_URL), nao no host do teste: a api-transacoes nao tem POST /contas
  (o original dava 404 no on_start e nenhuma transferencia acontecia);
- o payload inclui "senha", obrigatoria no ContaIn da api-contas (sem ela: 422);
- o host do teste (api-transacoes) vem de LOCUST_HOST / campo "Host" da UI, como antes.

Execucao local:
    CONTAS_URL=http://localhost:8081 locust -f locustfile.py --host http://localhost:8082

Execucao em Kubernetes (Deployment, k8s/loadtest/locust.yaml):
    LOCUST_HOST=http://api-transacoes.tipsbank-transacoes:8080
    CONTAS_URL=http://api-contas.tipsbank-contas:8080
"""
import os
import random
import uuid
from locust import HttpUser, task, between, events


CONTAS_URL = os.environ.get("CONTAS_URL", "http://api-contas.tipsbank-contas:8080").rstrip("/")
CONTAS_CRIADAS: list[str] = []


class UsuarioBanco(HttpUser):
    wait_time = between(0.5, 2)

    def on_start(self):
        """Cria uma conta por usuario (na api-contas) para termos saldo disponivel."""
        documento = "".join(random.choices("0123456789", k=11))
        payload = {
            "titular": f"Locust {uuid.uuid4().hex[:6]}",
            "documento": documento,
            "senha": uuid.uuid4().hex[:12],
            "saldo_inicial": "10000.00",
        }
        # URL absoluta: o HttpSession do Locust usa o host do teste so para caminhos relativos
        with self.client.post(
            f"{CONTAS_URL}/contas",
            json=payload,
            name="/contas (setup)",
            catch_response=True,
        ) as r:
            if r.status_code == 201:
                CONTAS_CRIADAS.append(r.json()["id"])
                r.success()
            else:
                r.failure(f"falha criando conta: {r.status_code}")

    @task(3)
    def transferir(self):
        if len(CONTAS_CRIADAS) < 2:
            return
        origem, destino = random.sample(CONTAS_CRIADAS, 2)
        valor = round(random.uniform(1, 50), 2)
        self.client.post(
            "/transferencias",
            json={"origem_id": origem, "destino_id": destino, "valor": str(valor)},
            name="/transferencias",
        )

    @task(1)
    def consultar_extrato(self):
        if not CONTAS_CRIADAS:
            return
        conta = random.choice(CONTAS_CRIADAS)
        self.client.get(f"/extrato/{conta}", name="/extrato/:id")


@events.test_stop.add_listener
def resumo(environment, **_):
    print(f"\nContas criadas durante o teste: {len(CONTAS_CRIADAS)}")
