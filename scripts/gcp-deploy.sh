#!/usr/bin/env bash
# Despliegue completo en GCP (GKE Autopilot regional, perfil costo cero).
# Uso: scripts/gcp-deploy.sh <PROJECT_ID> [REGION]
set -euo pipefail

PROJECT="${1:?Uso: $0 <PROJECT_ID> [ZONA]}"
# Acepta región ("us-central1") o zona ("us-central1-a") y normaliza a región:
# GKE Autopilot solo admite ubicaciones regionales.
LOC="${2:-us-central1}"
if [[ "$LOC" =~ ^(.*-[a-z]+[0-9]+)-[a-z]$ ]]; then
  REGION="${BASH_REMATCH[1]}"
  echo "    (aviso: '$LOC' es una zona; Autopilot es regional -> se usará '$REGION')"
else
  REGION="$LOC"
fi
REPO="${REGION}-docker.pkg.dev/${PROJECT}/otel-lab"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Opcional: exporta BILLING_ACCOUNT_ID para crear la alerta de presupuesto.
#   export BILLING_ACCOUNT_ID=019761-DB9128-F59D76
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:-}"
TF_BUDGET_VAR=()
if [ -n "$BILLING_ACCOUNT_ID" ]; then
  TF_BUDGET_VAR=(-var "billing_account_id=$BILLING_ACCOUNT_ID")
fi

echo "==> Proyecto: $PROJECT | Región: $REGION"

echo "==> 1/5 Habilitando APIs necesarias"
gcloud services enable container.googleapis.com artifactregistry.googleapis.com \
  logging.googleapis.com --project "$PROJECT"
# La API de presupuestos es opcional: si falla, el despliegue continúa igual
if [ -n "$BILLING_ACCOUNT_ID" ]; then
  gcloud services enable billingbudgets.googleapis.com --project "$PROJECT" \
    || echo "    (aviso: no se pudo habilitar billingbudgets; se omitirá el presupuesto)"
fi

echo "==> 2/5 Creando Artifact Registry y cluster (terraform apply)"
cd "$ROOT/deploy/gcp/terraform"
terraform init -input=false
# Se crean primero registro y cluster; el chart necesita las imágenes publicadas
terraform apply -input=false -auto-approve \
  -var "project_id=$PROJECT" -var "region=$REGION" \
  "${TF_BUDGET_VAR[@]+"${TF_BUDGET_VAR[@]}"}" \
  -target=google_artifact_registry_repository.repo \
  -target=google_container_cluster.gke \
  -target=google_service_account.otel_collector \
  -target=google_project_iam_member.log_writer \
  -target=google_service_account_iam_member.wi_binding \
  -target=google_project_iam_member.gke_nodes_artifact_reader

echo "==> 3/5 Construyendo y publicando imágenes"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
for svc in service-a service-b; do
  docker build --platform linux/amd64 -t "${REPO}/${svc}:1.0.0" "$ROOT/services/${svc}"
  docker push "${REPO}/${svc}:1.0.0"
done

echo "==> 4/5 Desplegando la aplicación con Helm"
terraform apply -input=false -auto-approve \
  -var "project_id=$PROJECT" -var "region=$REGION" \
  "${TF_BUDGET_VAR[@]+"${TF_BUDGET_VAR[@]}"}"

echo "==> 5/5 Verificando"
gcloud container clusters get-credentials otel-lab --region "$REGION" --project "$PROJECT"
kubectl -n observability rollout status deploy/service-a --timeout=300s
kubectl -n observability rollout status deploy/service-b --timeout=300s
kubectl -n observability get pods

cat <<EOF

LISTO. Para generar tráfico y ver evidencias:

  kubectl -n observability port-forward svc/service-a 8000:8000 &
  kubectl -n observability port-forward svc/jaeger-ui 16686:16686 &
  for i in \$(seq 1 40); do curl -s "localhost:8000/api/orders/\$((RANDOM%5+1))?qty=2" >/dev/null; done

  Jaeger UI:      http://localhost:16686
  Cloud Logging:  https://console.cloud.google.com/logs/query?project=$PROJECT

CUANDO TERMINES, DESTRUYE TODO:  scripts/gcp-destroy.sh $PROJECT $REGION
EOF
