output "ecr_service_a" {
  description = "Repositorio ECR para la imagen de service-a"
  value       = aws_ecr_repository.service_a.repository_url
}

output "ecr_service_b" {
  description = "Repositorio ECR para la imagen de service-b"
  value       = aws_ecr_repository.service_b.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.cluster.name
}

# Sin ALB, la IP pública vive en la ENI de la task y cambia en cada despliegue.
# Este comando la resuelve; también lo hace scripts/aws-endpoints.sh.
output "como_obtener_endpoints" {
  description = "Comando para resolver las IPs públicas de service-a y Prometheus"
  value       = "bash ../../../scripts/aws-endpoints.sh ${var.region}"
}

output "consola_xray" {
  description = "Trazas en X-Ray"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#xray:traces/query"
}

output "consola_logs" {
  description = "Logs correlacionados en CloudWatch"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#logsV2:log-groups/log-group/$252Fotel-lab$252Fecs"
}
