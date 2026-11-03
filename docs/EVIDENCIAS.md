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

---

## Etapa 1.2 — Build Distroless, scan com Trivy, assinatura Cosign

**Data**: 2026-11-03 · **Ferramentas**: Docker 29.1.3 + buildx 0.30.1, Trivy 0.69.3, Docker Scout 1.20.3, Cosign 3.1.4 · **Registry**: `ghcr.io/jlui70` (exigido pelo comando de compliance #1, que só aceita `ghcr.io/<user>`)

### Por que Distroless (multi-stage) reduz vulnerabilidades

Os Dockerfiles das APIs têm **dois estágios**:

1. **builder** (`python:3.x-slim`): tem `pip`, compiladores e shell. Instala as dependências com `pip install --target=/packages`. Esse estágio **não vai para a imagem final**.
2. **runtime** (`gcr.io/distroless/python3-*:nonroot`): recebe só o `/packages` e o `main.py`. Tem o interpretador Python e a glibc, e roda como o usuário `nonroot` (UID 65532).

Isso reduz vulnerabilidades por três motivos:
- **Menos pacotes, menos CVEs**: a imagem não tem `apt`, `bash`, `coreutils`, `curl` nem compiladores, e cada pacote a menos é um pacote a menos para ter CVE. O Trivy encontra só ~25 pacotes Python e as libs mínimas do Debian.
- **Menos superfície de ataque**: sem shell, quem conseguir executar código pela aplicação não tem `sh`, nem gerenciador de pacotes para instalar ferramentas, nem `curl` para baixar payloads (prova abaixo).
- **Não-root por padrão**: mesmo que alguém escape da aplicação, o processo não tem privilégio de root dentro do container.

O `--target=/packages` é usado em vez de um venv porque o venv guarda o caminho absoluto do `python3` do builder. No Distroless o binário fica em outro caminho e o venv quebraria. Com `PYTHONPATH=/packages` e `PATH=/packages/bin:$PATH`, o `python3` do runtime encontra as libs.

### Problema encontrado: as bases originais não passavam no critério

Primeiro escaneei as imagens base que vinham nos Dockerfiles:

```console
$ trivy image -q --severity HIGH,CRITICAL -f json gcr.io/distroless/python3-debian12:nonroot \
    | jq -r '[.Results[].Vulnerabilities[]?] | "total=\(length) CRITICAL=\(map(select(.Severity=="CRITICAL"))|length) com-fix=\(map(select(.Status=="fixed"))|length) will_not_fix=\(map(select(.Status=="will_not_fix"))|length)"'
total=63 CRITICAL=2 com-fix=45 will_not_fix=1

$ trivy image ... nginxinc/nginx-unprivileged:1.27-alpine   # mesmo filtro jq
total=60 CRITICAL=3 com-fix=60 will_not_fix=0
```

- **`python3-debian12`**: 45 CVEs já têm correção no Debian, mas a imagem Distroless ainda não foi reconstruída com essas correções. E, como ela não tem `apt`, **eu não consigo aplicar os patches no meu build**. Sobram ainda CVEs `will_not_fix` (zlib, CVE-2023-45853) e `affected` (ex.: sqlite, CVE-2025-7458, CRITICAL), que nenhuma atualização resolve.
- **`nginx-unprivileged:1.27-alpine`**: a linha 1.27 não recebe mais atualizações. As 60 CVEs já têm correção em versões mais novas.

### Alterações feitas

**APIs** (`apps/{api-contas,api-transacoes,auditoria}/Dockerfile`): troca para **Debian 13 (trixie)**. O builder e o runtime precisam ter **a mesma versão do Python**, porque o `/packages` contém wheels compilados para o Python do builder (ex.: `pydantic-core`, `psycopg-binary`).

```diff
-FROM python:3.11-slim-bookworm AS builder
+FROM python:3.13-slim-trixie AS builder
 ...
-FROM gcr.io/distroless/python3-debian12:nonroot
+FROM gcr.io/distroless/python3-debian13:nonroot
```

**web** (`apps/web/Dockerfile`): base atual com tag fixa (o compliance proíbe `:latest`), mais `apk upgrade` para aplicar as correções do Alpine publicadas depois da imagem base. Para isso o build vira root **apenas nesse passo** e volta para o UID 101:

```diff
-FROM nginxinc/nginx-unprivileged:1.27-alpine
+FROM nginxinc/nginx-unprivileged:1.31.7-alpine3.24
+USER root
+RUN apk upgrade --no-cache
+USER 101
```

**Dependências Python** (`requirements.txt` das 3 APIs): depois de trocar a base, o `trivy image` ainda apontava **3 HIGH no `starlette 0.38.6`** (CVE-2024-47874, CVE-2026-48818, CVE-2026-54283). O starlette é dependência **transitiva**: não aparece no `requirements.txt`, vem junto com o `fastapi==0.115.0`, que trava `starlette<0.39`. Por isso o `trivy fs apps/`, que só lê o que está declarado, dava 0. Só o `trivy image`, que lê o que foi realmente instalado em `/packages`, encontrou.

```diff
-fastapi==0.115.0
+fastapi==0.162.0
+starlette==1.10.0
```

Antes de mudar, confirmei com `pip install --dry-run` que o `fastapi` 0.162.0 resolve junto com os pins atuais (`pydantic==2.9.2`, `uvicorn==0.30.6`). Fixei o `starlette` explicitamente para a versão não mudar sozinha entre builds. Depois rodei de novo, no `docker compose`, todos os testes da etapa 1.1 (health, `/metrics`, login 200/401, validação 422, transferência, auditoria, extrato e proxy do `web`): tudo OK.

### Build

```console
$ R=ghcr.io/jlui70; TAG=v1.0.0
$ for a in api-contas api-transacoes auditoria web; do docker build -t $R/tipsbank-$a:$TAG apps/$a; done

$ docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}' | grep -E 'REPOSITORY|ghcr.io/jlui70'
REPOSITORY:TAG                                  IMAGE ID       SIZE
ghcr.io/jlui70/tipsbank-api-contas:v1.0.0       d6f0139e1ef3   131MB
ghcr.io/jlui70/tipsbank-api-transacoes:v1.0.0   e7125437d9aa   132MB
ghcr.io/jlui70/tipsbank-auditoria:v1.0.0        58ade0b93e48   100MB
ghcr.io/jlui70/tipsbank-web:v1.0.0              e9ac58eededb   65.7MB
```

O `-t` dá o nome completo, com o registry. É por esse nome que o `docker push` sabe para onde enviar.

### Critério 1 — Trivy: 0 HIGH/CRITICAL nas 4 imagens

```console
$ for a in api-contas api-transacoes auditoria web; do
    n=$(trivy image -q --severity HIGH,CRITICAL --ignore-unfixed -f json $R/tipsbank-$a:v1.0.0 | jq "[.Results[].Vulnerabilities[]?] | length")
    t=$(trivy image -q --severity HIGH,CRITICAL -f json $R/tipsbank-$a:v1.0.0 | jq "[.Results[].Vulnerabilities[]?] | length")
    echo "$a  com-fix=$n  total=$t"; done
api-contas  com-fix=0  total=29
api-transacoes  com-fix=0  total=29
auditoria  com-fix=0  total=29
web  com-fix=0  total=0
```

O `jq` soma as vulnerabilidades de **todos** os alvos que o Trivy escaneia: o sistema operacional e cada pacote Python. A tabela padrão do Trivy mostra a mesma coisa, só que com uma linha por alvo (são 21 a 28 por imagem):

```console
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed ghcr.io/jlui70/tipsbank-api-contas:v1.0.0
│ ghcr.io/jlui70/tipsbank-api-contas:v1.0.0 (debian 13.7) │   debian   │        0        │    -    │
│ packages/SQLAlchemy-2.0.35.dist-info/METADATA           │ python-pkg │        0        │    -    │
│ packages/bcrypt-4.2.0.dist-info/METADATA                │ python-pkg │        0        │    -    │
│ packages/fastapi-0.162.0.dist-info/METADATA             │ python-pkg │        0        │    -    │
│ packages/starlette-1.10.0.dist-info/METADATA            │ python-pkg │        0        │    -    │
│ ...                                                     │ python-pkg │        0        │    -    │
```

**Justificativa do `--ignore-unfixed`**: as 29 HIGH que aparecem sem o filtro nas APIs são **todas `affected`**, ou seja, o Debian conhece a falha mas ainda **não publicou correção**. Não há versão para onde atualizar:

```console
$ trivy image -q --severity HIGH,CRITICAL -f json $R/tipsbank-api-contas:v1.0.0 | jq -r '.Results[].Vulnerabilities[]? | "\(.Severity) \(.Status)"' | sort | uniq -c
     29 HIGH affected

$ ... | jq -r '[.Results[].Vulnerabilities[]?.VulnerabilityID] | unique | length'
13

$ ... | jq -r '.Results[].Vulnerabilities[]? | .PkgName' | sort | uniq -c
      2 libexpat1
      1 libncursesw6
      5 libpython3.13-minimal
      5 libpython3.13-stdlib
      1 libsqlite3-0
      1 libtinfo6
      4 libuuid1
      5 python3.13-minimal
      5 python3.13-venv
```

São **13 CVEs únicas**, contadas mais de uma vez porque estão em subpacotes do mesmo código-fonte (as mesmas 5 do CPython aparecem em 4 pacotes). Nenhuma é CRITICAL. Quando o Debian publicar as correções, basta reconstruir as imagens. Em comparação com a base original, saímos de 63 (2 CRITICAL, 45 com correção pendente) para 0 com correção disponível.

### Docker Scout (segunda opinião, outro banco de CVEs)

```console
$ for a in api-contas api-transacoes auditoria web; do docker scout quickview local://$R/tipsbank-$a:v1.0.0; done
 Target     │  local://ghcr.io/jlui70/tipsbank-api-contas:v1.0.0      │    0C     0H     0M     0L
 Target     │  local://ghcr.io/jlui70/tipsbank-api-transacoes:v1.0.0  │    0C     0H     0M     0L
 Target     │  local://ghcr.io/jlui70/tipsbank-auditoria:v1.0.0       │    0C     0H     0M     0L
 Target     │  local://ghcr.io/jlui70/tipsbank-web:v1.0.0             │    0C     1H     5M     5L     1?
   Base image │  nginxinc/nginx-unprivileged:1-alpine                 │    8C    23H     5M     5L     1?

$ docker scout cves --only-severity critical,high local://$R/tipsbank-web:v1.0.0
   0C     1H     0M     0L  libxml2 2.13.9-r2
    ✗ HIGH CVE-2026-86140
      Affected range : <=2.13.9-r2
      Fixed version  : not fixed
```

- **APIs**: o Scout confirma o Trivy, com 0 em todas as severidades.
- **web**: o Scout encontra 1 HIGH no `libxml2` (CVE-2026-86140) que o Trivy não lista, nem sem o filtro, porque os bancos de CVEs são diferentes. Ela também está **sem correção publicada** (`not fixed`). Por isso vale usar dois scanners: um cobre o que falta no outro.
- A linha `Base image` é uma **inferência** do Scout (a imagem foi construída sem *provenance attestation*, então ele "adivinha" a base). Pelo mesmo motivo ele identifica a base das APIs como `distroless/cc-debian13`, quando ela é `python3-debian13`. Essa linha não deve ser lida como medição da base real.

### Critério 2 — Usuário não-root (65532 nas APIs, 101 no web)

```console
$ for a in api-contas api-transacoes auditoria web; do echo "$a User=$(docker inspect $R/tipsbank-$a:v1.0.0 --format '{{.Config.User}}')"; done
api-contas User=65532
api-transacoes User=65532
auditoria User=65532
web User=101

$ docker run --rm --entrypoint id $R/tipsbank-web:v1.0.0
uid=101(nginx) gid=101(nginx) groups=101(nginx),101(nginx)
```

Prova de que a imagem Distroless **não tem shell**:

```console
$ docker run --rm --entrypoint sh $R/tipsbank-api-contas:v1.0.0 -c id
docker: Error response from daemon: ... exec: "sh": executable file not found in $PATH
```

### Critério 3 — Tamanho (Python < 150 MB, web < 30 MB)

Existem duas medidas de tamanho: o `docker images` mostra a imagem **descompactada** no disco local, e o registry guarda as camadas **comprimidas**, que é o que o nó do cluster baixa. Medi o tamanho comprimido no ghcr.io somando as camadas do manifest:

```console
$ for a in api-contas api-transacoes auditoria web; do
    printf "%-24s %s MB\n" $a $(docker buildx imagetools inspect --raw $R/tipsbank-$a:v1.0.0 | jq '[.layers[].size] | add / 1e6 * 10 | round / 10'); done
api-contas               46 MB
api-transacoes           46.2 MB
auditoria                35.6 MB
web                      28.7 MB
```

| Imagem | Descompactada | Comprimida (registry) | Limite | |
|---|---|---|---|---|
| api-contas | 131 MB | 46,0 MB | 150 MB | ✅ |
| api-transacoes | 132 MB | 46,2 MB | 150 MB | ✅ |
| auditoria | 100 MB | 35,6 MB | 150 MB | ✅ |
| web | 65,7 MB | **28,7 MB** | 30 MB | ✅ |

As APIs ficam abaixo do limite nas duas medidas. Para o `web`, o critério se refere ao tamanho comprimido: até a base original `1.27-alpine` já passava de 30 MB descompactada. No `web`, a maior camada é o próprio nginx (~17 MB). O `apk upgrade` acrescenta ~1,9 MB e o HTML ~1 MB.

### Push para o ghcr.io

```console
$ for a in api-contas api-transacoes auditoria web; do docker push $R/tipsbank-$a:v1.0.0; done
...
b64fe4bb89ff: Mounted from jlui70/tipsbank-auditoria
v1.0.0: digest: sha256:c919b4d3096a906937522d512143c0020100c1ac31ac88e79849aac777f42e41 size: 10985
```

`Mounted from` significa que o registry **reaproveitou** camadas que já tinha recebido de outra imagem. As camadas são endereçadas pelo sha256 do conteúdo, então a base comum das 3 APIs só é enviada uma vez.

| Imagem | Digest |
|---|---|
| tipsbank-api-contas | `sha256:c919b4d3096a906937522d512143c0020100c1ac31ac88e79849aac777f42e41` |
| tipsbank-api-transacoes | `sha256:415945fea3f0cd8e69fb4e736e6f071bde7ad948783a22b09c30aac7c12a2c6e` |
| tipsbank-auditoria | `sha256:64768d4d27788fe6e390ffb27e1cca5ae068a79a1779e98eb6702ba1ab2af3b2` |
| tipsbank-web | `sha256:852f48826838c0de6a5dd73880ef13c151464f6f26bdc2ae90f5d9423b966ded` |

Os 4 pacotes foram deixados **públicos** no GitHub (Package settings → Change visibility), para o cluster baixar sem `imagePullSecret`. Teste de acesso anônimo, com uma configuração do Docker vazia (sem nenhuma credencial):

```console
$ ANON=$(mktemp -d); for a in api-contas api-transacoes auditoria web; do
    DOCKER_CONFIG=$ANON docker buildx imagetools inspect $R/tipsbank-$a:v1.0.0 >/dev/null && echo "$a publico"; done
api-contas publico
api-transacoes publico
auditoria publico
web publico
```

### Assinatura com Cosign (keyless / OIDC)

Escolhi a assinatura **keyless** porque o comando de compliance #7 do manual verifica com `--certificate-identity-regexp` e `--certificate-oidc-issuer-regexp`. Essas opções só se aplicam a assinaturas keyless. Com chave local (`cosign.key`), o comando exigiria `--key` e falharia.

```console
$ for a in api-contas api-transacoes auditoria web; do
    DIGEST=$(docker inspect --format '{{index .RepoDigests 0}}' $R/tipsbank-$a:v1.0.0)
    cosign sign --yes "$DIGEST"; done
```

- **Assinar pelo digest** (`imagem@sha256:...`) e não pela tag: uma tag pode passar a apontar para outra imagem, o digest não. A assinatura fica presa exatamente à imagem que foi escaneada.
- **Como o keyless funciona**:
  1. O cosign abre o navegador para o login OIDC (usei GitHub).
  2. O **Fulcio**, a autoridade certificadora do Sigstore, emite um certificado válido por ~10 minutos, com a minha identidade.
  3. A assinatura é registrada no **Rekor**, o log público de transparência.
  4. A assinatura é gravada no próprio ghcr.io, ligada à imagem.
- **Identidade**: usei o e-mail noreply do GitHub (`188764035+jlui70@users.noreply.github.com`) em vez do e-mail pessoal, porque a identidade fica pública e permanente no certificado e no Rekor.
- O `--yes` aceita o aviso de que a identidade será publicada. A variável `COSIGN_EXPERIMENTAL=1` do `scripts/build-e-assinar.sh` não é mais necessária no cosign 3.x, que já faz keyless por padrão.

A assinatura fica anexada à imagem como um *OCI referrer*:

```console
$ cosign tree $R/tipsbank-api-contas:v1.0.0
📦 Supply Chain Security Related artifacts for an image: ghcr.io/jlui70/tipsbank-api-contas:v1.0.0
└── 🔗 https://sigstore.dev/cosign/sign/v1 artifacts via OCI referrer: ghcr.io/jlui70/tipsbank-api-contas@sha256:f102fa38...
   └── 🍒 sha256:1d07d1748fcfbd2b6aa64c26d062773e377b991485c1e965740b7bb8756a0029
```

### Critério 4 — `cosign verify` passa nas 4 imagens

**Formato do comando de compliance #7:**

```console
$ for a in api-contas api-transacoes auditoria web; do img=$R/tipsbank-$a:v1.0.0
    cosign verify $img --certificate-identity-regexp '.*' --certificate-oidc-issuer-regexp '.*' >/dev/null && echo "OK: $img"; done

Verification for ghcr.io/jlui70/tipsbank-api-contas:v1.0.0 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
OK: ghcr.io/jlui70/tipsbank-api-contas:v1.0.0
OK: ghcr.io/jlui70/tipsbank-api-transacoes:v1.0.0
OK: ghcr.io/jlui70/tipsbank-auditoria:v1.0.0
OK: ghcr.io/jlui70/tipsbank-web:v1.0.0
```

As três verificações do cosign:
1. as informações da assinatura conferem com o digest da imagem;
2. a assinatura está registrada no Rekor;
3. o certificado foi emitido pelo Fulcio.

**Verificação rigorosa**, com a identidade e o emissor exatos. O `'.*'` do compliance aceita uma assinatura keyless de **qualquer pessoa**. É esta versão que garante que fui **eu** quem assinou:

```console
$ for a in api-contas api-transacoes auditoria web; do img=$R/tipsbank-$a:v1.0.0
    cosign verify $img \
      --certificate-identity=188764035+jlui70@users.noreply.github.com \
      --certificate-oidc-issuer=https://github.com/login/oauth >/dev/null && echo "OK: $img"; done
OK: ghcr.io/jlui70/tipsbank-api-contas:v1.0.0
OK: ghcr.io/jlui70/tipsbank-api-transacoes:v1.0.0
OK: ghcr.io/jlui70/tipsbank-auditoria:v1.0.0
OK: ghcr.io/jlui70/tipsbank-web:v1.0.0
```

**Teste negativo**: com outra identidade, a verificação falha, como deve:

```console
$ cosign verify $R/tipsbank-api-contas:v1.0.0 \
    --certificate-identity=luiz7030@gmail.com --certificate-oidc-issuer=https://github.com/login/oauth
Error: no matching attestations: failed to verify certificate identity: no matching CertificateIdentity found,
last error: expected SAN value "luiz7030@gmail.com", got "188764035+jlui70@users.noreply.github.com"
```

### Nota sobre o `web` e o critério "Distroless"

O `web` usa `nginx-unprivileged` (Alpine). Ele é **não-root (UID 101) e minimal**, mas **não é Distroless** no sentido estrito: tem o shell do Alpine (`/bin/sh`) e o `apk`. Conforme o manual, o critério "100% Distroless" vale para as 3 APIs Python, e o `web` é a alternativa nonroot/minimal. Os demais critérios (não rodar como root, não usar `:latest`, 0 HIGH/CRITICAL com correção disponível, imagem assinada) valem integralmente para ele e foram atendidos.

### Resultado

| Critério | api-contas | api-transacoes | auditoria | web |
|---|---|---|---|---|
| Trivy 0 HIGH/CRITICAL (com correção disponível) | ✅ | ✅ | ✅ | ✅ |
| Docker Scout | ✅ 0C 0H | ✅ 0C 0H | ✅ 0C 0H | ✅ 1H sem correção |
| `cosign verify` (compliance #7 e rigoroso) | ✅ | ✅ | ✅ | ✅ |
| Usuário não-root | ✅ 65532 | ✅ 65532 | ✅ 65532 | ✅ 101 |
| Tamanho (Python < 150 MB, web < 30 MB) | ✅ 46,0 MB | ✅ 46,2 MB | ✅ 35,6 MB | ✅ 28,7 MB |
