output "cluster_name" {
  value = google_container_cluster.gke.name
}

output "artifact_registry" {
  description = "Destino de las imágenes de los servicios"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/otel-lab"
}

output "collector_service_account" {
  value = google_service_account.otel_collector.email
}

output "credenciales_kubectl" {
  description = "Conecta kubectl al cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.gke.name} --region ${var.region} --project ${var.project_id}"
}

# Los Services son ClusterIP (no LoadBalancer) para evitar el costo del
# balanceador de Google: se accede por port-forward, que es gratis.
output "acceso_jaeger_ui" {
  value = "kubectl -n observability port-forward svc/jaeger-ui 16686:16686  # luego abre http://localhost:16686"
}

output "acceso_service_a" {
  value = "kubectl -n observability port-forward svc/service-a 8000:8000  # luego curl http://localhost:8000/api/orders/1?qty=2"
}

output "acceso_grafana" {
  value = "kubectl -n observability port-forward svc/grafana 3000:3000  # dashboard de 6 paneles en http://localhost:3000"
}

output "acceso_prometheus" {
  value = "kubectl -n observability port-forward svc/prometheus 9090:9090  # http://localhost:9090"
}

output "consola_cloud_logging" {
  description = "Logs con trace_id en Cloud Logging"
  value       = "https://console.cloud.google.com/logs/query;query=logName%3D%22projects%2F${var.project_id}%2Flogs%2Fotel-lab%22?project=${var.project_id}"
}
