#!/usr/bin/env bash
# ============================================================================
# ORELHA — fase 1/2: abre as portas 80/443 pra VM receber o webhook da Meta.
# Onde roda: CLOUD SHELL (fora da VM).
# Uso:  gcp-firewall.sh <PROJETO_GCP> <NOME_VM> <ZONA>
# Ex.:  gcp-firewall.sh meu-projeto hunter-vm southamerica-east1-a
# Idempotente: pode rodar de novo sem quebrar nada.
# ============================================================================
set -euo pipefail
PROJECT="${1:?uso: gcp-firewall.sh PROJETO_GCP NOME_VM ZONA}"
VM="${2:?falta NOME_VM}"
ZONE="${3:?falta ZONA}"

gcloud config set project "$PROJECT" --quiet
gcloud compute instances add-tags "$VM" --zone="$ZONE" --tags=hunter-https --quiet

if gcloud compute firewall-rules describe allow-hunter-https >/dev/null 2>&1; then
  echo "regra allow-hunter-https ja existe — ok"
else
  gcloud compute firewall-rules create allow-hunter-https \
    --network=default --direction=INGRESS --action=ALLOW \
    --rules=tcp:80,tcp:443 --source-ranges=0.0.0.0/0 \
    --target-tags=hunter-https --quiet
fi

echo "OK FIREWALL: 80/443 abertos para a tag hunter-https (VM $VM, projeto $PROJECT)"

