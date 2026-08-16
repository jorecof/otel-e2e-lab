output "alb_dns" {
  description = "Endpoint público de service-a"
  value       = aws_lb.alb.dns_name
}

output "ecr_service_a" {
  value = aws_ecr_repository.service_a.repository_url
}

output "ecr_service_b" {
  value = aws_ecr_repository.service_b.repository_url
}

output "amp_endpoint" {
  value = aws_prometheus_workspace.amp.prometheus_endpoint
}
