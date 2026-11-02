# TipsBank — Evidências

Registro dos comandos e saídas que comprovam cada critério de aceite do `docs/MANUAL-ALUNO.md`.

---

# SEMANA 1 — Fundações

## Etapa 1.1 — Entender a aplicação localmente

**Data**: 2026-11-02 · **Ambiente**: Zorin OS, Docker Engine + `docker-compose-v2`, `docker compose up --build`

### Visão geral dos serviços (explicação de 2 minutos)

| Serviço | Porta local | O que faz |
|---|---|---|
| `postgres` | 5432 | Banco `tipsbank`, com as tabelas `contas` e `transacoes`. Inicializado por `sql/init.sql`, que cria as 2 contas seed com `senha_hash` bcrypt pré-computado (senha `giropops`). |
| `api-contas` | 8081 | CRUD de contas, `POST /login` (valida CPF + senha com bcrypt) e `POST /contas/{id}/saldo` (débito/crédito). Nunca devolve `senha_hash`, porque o modelo de saída `ContaOut` não tem esse campo. |
| `api-transacoes` | 8082 | `POST /transferencias` **debita** a origem e **credita** o destino chamando a `api-contas` via HTTP. Se o crédito falha, faz um estorno compensatório. Depois grava a transação na tabela `transacoes` (Postgres) e **publica o evento** na `auditoria`. Também tem `GET /extrato/{conta_id}`. |
| `auditoria` | 8083 | Recebe eventos em `POST /eventos` e anexa uma linha JSON em `/data/eventos-YYYY-MM-DD.jsonl`. Em produção esse diretório será um PV NFS RWX. |
| `web` | 8080 | SPA estática servida por `nginx-unprivileged` (UID 101). Faz proxy reverso de `/api/contas/`, `/api/transacoes/` e `/api/auditoria/` para as 3 APIs. |

**Fluxo de uma transferência**: SPA → `web` (nginx) → `api-transacoes` → `api-contas` (débito + crédito) → Postgres (grava a transação) → `auditoria` (linha no `.jsonl`).

**Observações da leitura do código** (pontos a considerar nas próximas semanas):
- Débito e crédito são duas chamadas HTTP separadas, sem transação distribuída. A consistência depende do estorno compensatório.
- Se a `auditoria` estiver fora do ar, a transferência **conclui mesmo assim** e o evento se perde. A `api-transacoes` só registra `auditoria indisponivel` no log. Isso reforça a importância das probes e do monitoramento da `auditoria` (Semana 3).
- A `api-transacoes` também acessa o Postgres (`DB_URL`). Isso vai importar nas NetworkPolicies (Semana 2).
- O nome do arquivo de auditoria usa a data em **UTC**. Depois das 21h no horário de Brasília, os eventos já caem no arquivo do dia seguinte.

### Containers rodando

```console
$ docker compose ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
NAME                      IMAGE                         STATUS                    PORTS
tipsbank-api-contas       tipsbank/api-contas:dev       Up 36 minutes             0.0.0.0:8081->8080/tcp
tipsbank-api-transacoes   tipsbank/api-transacoes:dev   Up 36 minutes             0.0.0.0:8082->8080/tcp
tipsbank-auditoria        tipsbank/auditoria:dev        Up 36 minutes             0.0.0.0:8083->8080/tcp
tipsbank-postgres         postgres:16-alpine            Up 36 minutes (healthy)   0.0.0.0:5432->5432/tcp
tipsbank-web              tipsbank/web:dev              Up 36 minutes             0.0.0.0:8080->8080/tcp
```

```console
$ for p in 8081 8082 8083; do echo "$p -> $(curl -s localhost:$p/health/live)"; done
8081 -> {"status":"ok"}
8082 -> {"status":"ok","version":"v1"}
8083 -> {"status":"ok"}
$ curl -s localhost:8080/healthz
ok
```

### Critério 1 — `GET /contas` retorna as contas seed sem `senha_hash`

```console
$ curl -s localhost:8081/contas | jq
[
  { "id": "11111111-1111-1111-1111-111111111111", "titular": "Jeferson Fernando", "documento": "12345678901", "saldo": "10099.98" },
  { "id": "22222222-2222-2222-2222-222222222222", "titular": "LinuxTips SA",      "documento": "98765432100", "saldo": "600.00" },
  { "id": "7f0abc12-f7d3-4613-a575-bfe286f41711", "titular": "Descomplicador",    "documento": "11122233344", "saldo": "900.00" },
  { "id": "bfdc6562-27d7-4971-a728-25409b4445c1", "titular": "Luiz Caetano",      "documento": "13513660847", "saldo": "900.02" }
]

$ curl -s localhost:8081/contas | grep -c senha_hash
0
```

As 2 contas seed estão presentes. As outras duas foram criadas durante os testes: "Descomplicador" pelo `curl` do README e "Luiz Caetano" pela SPA. Nenhuma resposta contém `senha_hash`.

### Critério 2 — Login: 200 com a senha certa, 401 com a errada

```console
$ curl -s -w '\nHTTP %{http_code}\n' -X POST localhost:8081/login \
    -H 'content-type: application/json' \
    -d '{"documento":"12345678901","senha":"giropops"}'
{"id":"11111111-1111-1111-1111-111111111111","titular":"Jeferson Fernando","documento":"12345678901","saldo":"10099.98"}
HTTP 200

$ curl -s -w '\nHTTP %{http_code}\n' -X POST localhost:8081/login \
    -H 'content-type: application/json' \
    -d '{"documento":"12345678901","senha":"senhaerrada"}'
{"detail":"credenciais invalidas"}
HTTP 401
```

### Critério 3 — Transferência de R$ 100 muda o saldo de ambas as contas

Saldo **antes**:
```console
$ curl -s localhost:8081/contas | jq -r '.[] | select(.documento=="12345678901" or .documento=="98765432100") | "\(.titular): \(.saldo)"'
Jeferson Fernando: 10099.98
LinuxTips SA: 600.00
```

Transferência:
```console
$ curl -s -w '\nHTTP %{http_code}\n' -X POST localhost:8082/transferencias \
    -H 'content-type: application/json' \
    -d '{"origem_id":"11111111-1111-1111-1111-111111111111","destino_id":"22222222-2222-2222-2222-222222222222","valor":"100.00"}'
{"id":"be2b3fa4-a52f-4e7f-aa1c-59832b6ad731","origem_id":"11111111-1111-1111-1111-111111111111","destino_id":"22222222-2222-2222-2222-222222222222","valor":"100.00","status":"concluida"}
HTTP 201
```

Saldo **depois**:
```console
Jeferson Fernando: 9999.98    # -100,00
LinuxTips SA: 700.00          # +100,00
```

### Critério 4 — Uma linha no `/data/eventos-YYYY-MM-DD.jsonl` por transferência

O container `auditoria` é **Distroless** (sem shell nem `cat`), então `docker exec ... cat` não funciona. O arquivo foi lido com `docker cp` para stdout, que gera um tar, extraído com `tar -xO`:

```console
$ curl -s localhost:8083/arquivos
["eventos-2026-11-02.jsonl"]

$ docker cp tipsbank-auditoria:/data/eventos-2026-11-02.jsonl - | tar -xO | wc -l
5

$ docker exec tipsbank-postgres psql -U tipsbank -d tipsbank -t \
    -c "select count(*) from transacoes where status='concluida'"
     5
```

5 transferências concluídas no Postgres e 5 linhas no `.jsonl`. A última linha corresponde à transferência do critério 3 (mesmo `transacao_id`):

```console
$ docker cp tipsbank-auditoria:/data/eventos-2026-11-02.jsonl - | tar -xO | tail -1 | jq
{
  "id": "06b179af-6d98-4db3-a648-92ffc04b482f",
  "recebido_em": "2026-11-02T20:47:09.447375+00:00",
  "tipo": "transferencia",
  "transacao_id": "be2b3fa4-a52f-4e7f-aa1c-59832b6ad731",
  "origem_id": "11111111-1111-1111-1111-111111111111",
  "destino_id": "22222222-2222-2222-2222-222222222222",
  "valor": "100.00",
  "versao_app": "v1"
}
```

### Critério 5 — SPA em `localhost:8080` funciona ponta a ponta

Testado no navegador com uma conta nova, "Teste Evidencia", criada só para os prints: abrir conta → login → dashboard → transferir R$ 100 para "Luiz Caetano" → extrato → auditoria. Essa foi a 6ª transferência do ambiente.

**1. Abrir conta** (`#/abrir`): titular, CPF, senha com confirmação e depósito inicial de R$ 1.000.

![Abrir conta](img/1.1-01-abrir-conta.png)

**2. Login** (`#/entrar`): CPF + senha da conta recém-criada.

![Login](img/1.1-02-entrar-conta.png)

**3. Dashboard** (`#/conta`): conta autenticada, saldo de R$ 1.000,00 e nenhuma movimentação.

![Dashboard](img/1.1-03-acesso-conta.png)

**4. Transferência** (`#/transferir`): origem "Teste Evidencia", destino "Luiz Caetano", R$ 100,00.

![Transferência](img/1.1-04-transferencia-conta.png)

**5. Comprovante**: autenticação `1b735c60-1bfc-43a6-be37-3171bcb2af04`, status `concluida`.

![Comprovante](img/1.1-05-transferencia2-conta.png)

**6. Extrato** (`localhost:8080/#/extrato`): débito de −R$ 100,00 com o mesmo ID `1b735c60`.

![Extrato](img/1.1-06-extrato-conta.png)

**7. Auditoria** (`localhost:8080/#/auditoria`): o evento `tx=1b735c60…` aparece no arquivo `2026-11-02`. Logo abaixo aparece o `tx=be2b3fa4…`, que é a transferência feita via `curl` no critério 3. A SPA e a API leem o mesmo `.jsonl`.

![Auditoria](img/1.1-07-auditoria-conta.png)

Conferência após o teste na SPA. As 6 transações concluídas no Postgres correspondem às 6 linhas no `.jsonl`, e os saldos fecham:

```console
$ curl -s localhost:8081/contas | jq -r '.[] | "\(.titular): \(.saldo)"'
Descomplicador: 900.00
Jeferson Fernando: 9999.98
LinuxTips SA: 700.00
Teste Evidencia: 900.00      # 1000 - 100
Luiz Caetano: 1000.02        # 900.02 + 100
$ docker exec tipsbank-postgres psql -U tipsbank -d tipsbank -t -c "select count(*) from transacoes"
     6
$ docker cp tipsbank-auditoria:/data/eventos-2026-11-02.jsonl - | tar -xO | wc -l
6
```

Validação do proxy reverso do nginx (o mesmo caminho que a SPA usa):

```console
$ curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/
200
$ curl -s localhost:8080/api/contas/contas | jq length
4
$ curl -s localhost:8080/api/auditoria/eventos | jq length
5
$ curl -s localhost:8080/api/transacoes/extrato/bfdc6562-27d7-4971-a728-25409b4445c1 | jq -c '.[] | {origem_id,destino_id,valor,status}'
{"origem_id":"7f0abc12-f7d3-4613-a575-bfe286f41711","destino_id":"bfdc6562-27d7-4971-a728-25409b4445c1","valor":"100.00","status":"concluida"}
{"origem_id":"bfdc6562-27d7-4971-a728-25409b4445c1","destino_id":"11111111-1111-1111-1111-111111111111","valor":"100.00","status":"concluida"}
{"origem_id":"bfdc6562-27d7-4971-a728-25409b4445c1","destino_id":"11111111-1111-1111-1111-111111111111","valor":"99.98","status":"concluida"}
```

O extrato da conta "Luiz Caetano" mostra as 3 transferências feitas pela SPA. O saldo bate: 1000,00 − 99,98 − 100,00 + 100,00 = **900,02**.

### Extra — usuário dos containers (base para a etapa 1.2)

```console
$ for c in api-contas api-transacoes auditoria web; do echo "$c user=$(docker inspect tipsbank-$c --format '{{.Config.User}}')"; done
api-contas user=65532
api-transacoes user=65532
auditoria user=65532
web user=101
```

### Resultado

| Critério | Status |
|---|---|
| `GET /contas` com seeds e sem `senha_hash` | ✅ |
| Login 200 / 401 | ✅ |
| Transferência de R$ 100 altera os 2 saldos | ✅ |
| 1 linha no `.jsonl` por transferência | ✅ (5/5 via curl, 6/6 após o teste na SPA) |
| SPA ponta a ponta | ✅ |
