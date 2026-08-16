output "cluster_name" {
  value = google_container_cluster.gke.name
}

output "artifact_registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/otel-lab"
}

output "collector_service_account" {
  value = google_service_account.otel_collector.email
}
