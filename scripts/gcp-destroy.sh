#!/usr/bin/env bash
# Destruye TODO lo creado en GCP y verifica que no quede nada facturando.
# Uso: scripts/gcp-destroy.sh <PROJECT_ID> [ZONA]
set -euo pipefail

PROJECT="${1:?Uso: $0 <PROJECT_ID> [ZONA]}"
ZONE="${2:-us-central1-a}"
REGION="${ZONE%-*}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT/deploy/gcp/terraform"
terraform destroy -input=false -auto-approve \
  -var "project_id=$PROJECT" -var "zone=$ZONE" -var "region=$REGION"

echo
echo "==> Verificación: nada debe aparecer debajo de cada línea"
echo "--- Clusters GKE ---"
gcloud container clusters list --project "$PROJECT" --format="value(name)" || true
echo "--- Balanceadores (reglas de reenvío) ---"
gcloud compute forwarding-rules list --project "$PROJECT" --format="value(name)" || true
echo "--- Discos persistentes ---"
gcloud compute disks list --project "$PROJECT" --format="value(name)" || true
echo "--- Repositorios de Artifact Registry ---"
gcloud artifacts repositories list --project "$PROJECT" --format="value(name)" || true
echo
echo "Si alguna lista salió con contenido, bórralo a mano antes de cerrar."
