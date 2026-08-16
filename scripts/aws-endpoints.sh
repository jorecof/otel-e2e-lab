#!/usr/bin/env bash
# Resuelve las IPs públicas de las tasks (sin ALB, la IP vive en la ENI).
# Uso: scripts/aws-endpoints.sh [REGION]
set -euo pipefail

REGION="${1:-us-east-1}"

task_ip() {
  local svc="$1"
  local task eni
  task="$(aws ecs list-tasks --cluster otel-lab --service-name "$svc" \
    --region "$REGION" --query 'taskArns[0]' --output text 2>/dev/null || echo None)"
  if [ -z "$task" ] || [ "$task" = "None" ]; then
    echo ""
    return 0
  fi

  eni="$(aws ecs describe-tasks --cluster otel-lab --tasks "$task" --region "$REGION" \
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" \
    --output text 2>/dev/null || echo None)"
  if [ -z "$eni" ] || [ "$eni" = "None" ]; then
    echo ""
    return 0
  fi

  aws ec2 describe-network-interfaces --network-interface-ids "$eni" --region "$REGION" \
    --query 'NetworkInterfaces[0].Association.PublicIp' --output text 2>/dev/null || echo ""
}

SVC_A="$(task_ip service-a)"
PROM="$(task_ip prometheus)"

cat <<EOF

==================== ENDPOINTS DEL LABORATORIO (AWS) ====================
  service-a   http://${SVC_A:-<no disponible>}:8000/api/orders/1?qty=2
  Prometheus  http://${PROM:-<no disponible>}:9090/graph

  Trazas (X-Ray):
    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#xray:traces/query
  Logs con trace_id (CloudWatch):
    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/\$252Fotel-lab\$252Fecs

  Generar tráfico:
    for i in \$(seq 1 40); do curl -s "http://${SVC_A}:8000/api/orders/\$((RANDOM%5+1))?qty=2" >/dev/null; done
=========================================================================
EOF
