terraform {
  required_version = ">= 1.7"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
    helm   = { source = "hashicorp/helm", version = "~> 2.16" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------- Artifact Registry para las imágenes de los servicios ----------
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "otel-lab"
  format        = "DOCKER"
}

# ---------- Cluster GKE Autopilot ----------
resource "google_container_cluster" "gke" {
  name                = "otel-lab"
  location            = var.region
  enable_autopilot    = true
  deletion_protection = false

  release_channel {
    channel = "REGULAR"
  }
}

# ---------- Service Account con Workload Identity para el Collector ----------
# Permite al exporter `googlecloud` escribir en Cloud Logging sin claves.
resource "google_service_account" "otel_collector" {
  account_id   = "otel-collector"
  display_name = "OTel Collector (Cloud Logging writer)"
}

resource "google_project_iam_member" "log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.otel_collector.email}"
}

resource "google_service_account_iam_member" "wi_binding" {
  service_account_id = google_service_account.otel_collector.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[observability/otel-collector]"
}

# ---------- Despliegue de la aplicación + pipeline con Helm ----------
provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.gke.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.gke.master_auth[0].cluster_ca_certificate)
  }
}

data "google_client_config" "default" {}

resource "helm_release" "otel_lab" {
  name             = "otel-lab"
  chart            = "${path.module}/../helm/otel-lab"
  namespace        = "observability"
  create_namespace = true

  set {
    name  = "image.registry"
    value = "${var.region}-docker.pkg.dev/${var.project_id}/otel-lab"
  }
  set {
    name  = "collector.gcpServiceAccount"
    value = google_service_account.otel_collector.email
  }
}
