#!/usr/bin/env bash
# Remove o Kyverno. O hook pre-delete do chart (Job) esta desligado por regra do
# desafio, entao os webhooks precisam ser apagados aqui; sem isso, com
# failurePolicy Fail, a API passa a recusar Pods sem ninguem para responder.
set -euo pipefail
kubectl delete cpol --all --ignore-not-found
helm uninstall kyverno -n kyverno --wait || true
kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
  -l webhook.kyverno.io/managed-by=kyverno --ignore-not-found
