#!/usr/bin/env bash
# Migracao de um banco JA inicializado para os usuarios de aplicacao (complemento da 4.4).
# Num cluster novo nada disso e preciso: o sql/roles-app.sh roda sozinho no initdb.
#
#   fase 1  ./k8s/contas/migrar-roles-app.sh usuarios   cria app_contas/app_transacoes (sem bloquear o superusuario)
#           kubectl apply dos Secrets + rollout das APIs (passam a usar os usuarios novos)
#   fase 2  ./k8s/contas/migrar-roles-app.sh bloquear   confere que ninguem usa o superusuario pela rede e
#                                                       rejeita o tipsbank no pg_hba (primary e replica)
# As senhas vao pelo STDIN do kubectl exec (nao aparecem na linha de comando nem no `ps`).
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
SECRET="$DIR/secret-db.yaml"
NS=tipsbank-contas
senha() { grep "$1:" "$SECRET" | cut -d'"' -f2; }

case "${1:-}" in
  usuarios)
    printf '%s\n%s\n' "$(senha CONTAS_DB_PASSWORD)" "$(senha TRANSACOES_DB_PASSWORD)" |
      kubectl -n $NS exec -i postgres-primary-0 -c postgres -- sh -c '
        read -r C; read -r T
        CONTAS_DB_PASSWORD=$C TRANSACOES_DB_PASSWORD=$T SEM_PG_HBA=1 sh /docker-entrypoint-initdb.d/roles-app.sh'
    kubectl -n $NS exec postgres-primary-0 -c postgres -- psql -U tipsbank -d tipsbank -c '\du'
    ;;
  bloquear)
    em_uso=$(kubectl -n $NS exec postgres-primary-0 -c postgres -- psql -U tipsbank -d tipsbank -Atc \
      "select count(*) from pg_stat_activity where usename='tipsbank' and client_addr is not null")
    if [[ "$em_uso" != "0" ]]; then
      echo "ABORTADO: ainda ha $em_uso conexoes de rede com o superusuario (rollout das APIs terminou?)"; exit 1
    fi
    for pod in postgres-primary-0 postgres-replica-0; do
      kubectl -n $NS exec -i $pod -c postgres -- sh -c '
        HBA="$PGDATA/pg_hba.conf"
        grep -q "^host all tipsbank all reject" "$HBA" || sed -i "s|^host all all all scram-sha-256|# 4.4: superusuario tipsbank so via socket local (kubectl exec)\nhost all tipsbank all reject\nhost all all all scram-sha-256|" "$HBA"
        psql -U tipsbank -d tipsbank -Atc "select pg_reload_conf()" >/dev/null
        grep -n "^host" "$HBA"'
      echo "  ($pod)"
    done
    ;;
  *) echo "uso: $0 usuarios|bloquear"; exit 1 ;;
esac
