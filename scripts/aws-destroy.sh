#!/usr/bin/env bash
# Destruye TODO lo creado en AWS y verifica que no quede nada facturando.
# Uso: scripts/aws-destroy.sh [REGION]
set -euo pipefail

REGION="${1:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT/deploy/aws/terraform"
terraform destroy -input=false -auto-approve -var "region=$REGION"

echo
echo "==> Verificación: nada debe aparecer debajo de cada línea"
echo "--- Servicios ECS ---"
aws ecs list-services --cluster otel-lab --region "$REGION" --query 'serviceArns' --output text 2>/dev/null || true
echo "--- Tasks en ejecución ---"
aws ecs list-tasks --cluster otel-lab --region "$REGION" --query 'taskArns' --output text 2>/dev/null || true
echo "--- Balanceadores ---"
aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null || true
echo "--- Workspaces de Amazon Managed Prometheus ---"
aws amp list-workspaces --region "$REGION" --query 'workspaces[].alias' --output text 2>/dev/null || true
echo "--- Repositorios ECR ---"
aws ecr describe-repositories --region "$REGION" --query 'repositories[].repositoryName' --output text 2>/dev/null || true
echo
echo "Si alguna lista salió con contenido, bórralo a mano antes de cerrar."
