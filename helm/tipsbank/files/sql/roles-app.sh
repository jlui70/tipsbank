#!/bin/sh
# Menor privilegio no banco (complemento da etapa 4.4).
#
# Antes: as duas APIs conectavam como "tipsbank", o SUPERUSUARIO criado pelo
# POSTGRES_USER da imagem oficial (Superuser, Create role, Replication, Bypass RLS).
# Uma senha vazada (exec, log, RCE na app) = controle total do banco.
#
# Depois:
#   app_contas      contas: SELECT, INSERT, UPDATE   movimentos: SELECT, INSERT
#   app_transacoes  transacoes: SELECT, INSERT, UPDATE
#   (nenhuma API faz DELETE nem DDL; levantado no codigo das apps)
#   tipsbank (superusuario) = so DBA, e so pelo socket local (kubectl exec, que o
#   RBAC da 4.4 restringe ao sre): conexao de rede com ele e REJEITADA no pg_hba.
#   log_connections/log_disconnections: quem conectou, com qual usuario, de onde.
#
# Roda de dois jeitos (idempotente):
#   - initdb: o entrypoint da imagem executa /docker-entrypoint-initdb.d em ordem
#     alfabetica; "roles-app.sh" vem DEPOIS de "init.sql" (as tabelas ja existem).
#   - banco existente: kubectl exec ... sh /docker-entrypoint-initdb.d/roles-app.sh
#     (com CONTAS_DB_PASSWORD e TRANSACOES_DB_PASSWORD no ambiente). Na migracao,
#     SEM_PG_HBA=1 cria os usuarios sem bloquear o superusuario ainda: as APIs antigas
#     conectam com ele ate o rollout terminar (k8s/contas/migrar-roles-app.sh).
# Senhas vem do Secret postgres-credentials (gerado por k8s/gerar-secrets.sh).
set -eu
: "${CONTAS_DB_PASSWORD:?CONTAS_DB_PASSWORD nao definido}"
: "${TRANSACOES_DB_PASSWORD:?TRANSACOES_DB_PASSWORD nao definido}"

psql -v ON_ERROR_STOP=1 \
     -v senha_contas="$CONTAS_DB_PASSWORD" -v senha_transacoes="$TRANSACOES_DB_PASSWORD" \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_contas') THEN
    CREATE ROLE app_contas LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_transacoes') THEN
    CREATE ROLE app_transacoes LOGIN;
  END IF;
END $$;

-- sem nenhum atributo especial; limite de conexoes por app (uma app nao esgota o banco:
-- max_connections=150; pools 3+2 por pod x HPA max: contas 10 pods, transacoes 15+1)
ALTER ROLE app_contas     WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
                               CONNECTION LIMIT 60 PASSWORD :'senha_contas';
ALTER ROLE app_transacoes WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
                               CONNECTION LIMIT 85 PASSWORD :'senha_transacoes';

-- ninguem conecta ou usa o schema "por padrao"; so quem recebe GRANT
REVOKE ALL ON DATABASE tipsbank FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE tipsbank TO app_contas, app_transacoes;
GRANT USAGE ON SCHEMA public TO app_contas, app_transacoes;

GRANT SELECT, INSERT, UPDATE ON contas     TO app_contas;
GRANT SELECT, INSERT         ON movimentos TO app_contas;
GRANT SELECT, INSERT, UPDATE ON transacoes TO app_transacoes;

-- trilha de acesso ao banco (vai para o log do container)
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_disconnections = on;
EOSQL

# superusuario so pelo socket local: rejeita conexao de REDE do tipsbank.
# Precisa vir ANTES da linha generica "host all all all scram-sha-256" (o pg_hba
# usa a primeira linha que casar).
HBA="$PGDATA/pg_hba.conf"
if [ "${SEM_PG_HBA:-0}" != "1" ] && ! grep -q '^host all tipsbank all reject' "$HBA"; then
  sed -i 's|^host all all all scram-sha-256|# 4.4: superusuario tipsbank so via socket local (kubectl exec)\nhost all tipsbank all reject\nhost all all all scram-sha-256|' "$HBA"
fi
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -Atc "SELECT pg_reload_conf()" >/dev/null
