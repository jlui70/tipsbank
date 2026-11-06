#!/bin/sh
# Etapa 3.3 — prepara o primary para a réplica streaming (postgres-replica).
# Roda UMA vez, no primeiro boot (initdb), antes do init.sql: o entrypoint da imagem
# oficial executa os arquivos de /docker-entrypoint-initdb.d em ordem alfabética.
# REPLICATION_PASSWORD vem do Secret postgres-credentials.
set -eu
: "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD não definido}"

psql -v ON_ERROR_STOP=1 -v senha="$REPLICATION_PASSWORD" \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
-- usuário só de replicação: não é superusuário e não lê as tabelas da app
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'senha';
-- slot físico: o primary guarda o WAL até a réplica confirmar que recebeu
SELECT pg_create_physical_replication_slot('postgres_replica_0');
EOSQL

# conexões de replicação (banco especial "replication") só do usuário replicator, com senha.
# Quem pode chegar na porta 5432 é decidido pela NetworkPolicy (2.5).
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
