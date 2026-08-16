#!/usr/bin/env bash
# Despliegue completo en AWS (ECS Fargate, perfil costo cero: sin ALB, sin AMP).
# Uso: scripts/aws-deploy.sh [REGION]
set -euo pipefail

REGION="${1:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
MY_IP="$(curl -s -m 10 ifconfig.me || echo '')"
ADMIN_CIDR="${MY_IP:+${MY_IP}/32}"
ADMIN_CIDR="${ADMIN_CIDR:-0.0.0.0/0}"

echo "==> Cuenta: $ACCOUNT | Región: $REGION | Acceso restringido a: $ADMIN_CIDR"

echo "==> 1/4 Creando repositorios ECR (terraform apply parcial)"
cd "$ROOT/deploy/aws/terraform"
terraform init -input=false
terraform apply -input=false -auto-approve \
  -var "region=$REGION" -var "admin_cidr=$ADMIN_CIDR" \
  -target=aws_ecr_repository.service_a -target=aws_ecr_repository.service_b

echo "==> 2/4 Construyendo y publicando imágenes"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"
for svc in service-a service-b; do
  docker build --platform linux/amd64 -t "${ECR}/otel-lab/${svc}:1.0.0" "$ROOT/services/${svc}"
  docker push "${ECR}/otel-lab/${svc}:1.0.0"
done

echo "==> 3/4 Desplegando el resto de la infraestructura"
terraform apply -input=false -auto-approve \
  -var "region=$REGION" -var "admin_cidr=$ADMIN_CIDR"

echo "==> 4/4 Esperando a que las tasks estén estables (puede tardar ~3 min)"
aws ecs wait services-stable --cluster otel-lab \
  --services service-a service-b postgres prometheus --region "$REGION"

bash "$ROOT/scripts/aws-endpoints.sh" "$REGION"

cat <<EOF

CUANDO TERMINES, DESTRUYE TODO:  scripts/aws-destroy.sh $REGION
EOF
