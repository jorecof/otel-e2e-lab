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

# =============================================================================
# PERFIL COSTO CERO
#   - GKE Autopilot: el free tier de GKE abona 74,40 USD/mes por cuenta de
#     facturación, equivalente a UN cluster Autopilot (o UN zonal Standard) al mes,
#     lo que cubre la tarifa de gestión de 0,10 USD/h.
#     Nota: Autopilot SIEMPRE es regional — la API rechaza clusters zonales con
#     "Autopilot clusters must be regional clusters". La exclusión del crédito
#     por regionalidad aplica a clusters de modo Standard, no a Autopilot.
#   - Los pods de Autopilot sí se cobran por recursos solicitados
#     (~0,0445 USD/vCPU-h). Con 1 réplica por servicio el laboratorio consume
#     ~1 vCPU y ~1,5 GiB => ~0,05 USD/h, cubierto por los 300 USD del free trial.
#   - Cloud Logging: 50 GiB/mes gratis por proyecto.
# Costo medido del laboratorio completo (~2 h): menos de 0,15 USD.
# =============================================================================

# ---------- Artifact Registry para las imágenes de los servicios ----------
# Free tier: 0,5 GB de almacenamiento gratuito al mes.
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "otel-lab"
  format        = "DOCKER"
}

data "google_project" "this" {
  project_id = var.project_id
}

# Permiso de lectura del registro para los nodos de GKE.
# Los nodos (también en Autopilot) corren con la Service Account por defecto de
# Compute Engine. Desde 2024 esa cuenta ya NO recibe el rol Editor de forma
# automática en proyectos nuevos, así que sin este binding los pods se quedan en
# ImagePullBackOff con "403 Forbidden" aunque la imagen exista en el registro.
resource "google_project_iam_member" "gke_nodes_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

# ---------- Cluster GKE Autopilot ----------
resource "google_container_cluster" "gke" {
  name     = "otel-lab"
  location = var.region # Autopilot exige ubicación regional

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

  # El pool de identidades (PROJECT.svc.id.goog) solo existe después de que se
  # crea el primer cluster con Workload Identity. Sin esta dependencia, el apply
  # falla con "Identity Pool does not exist".
  depends_on = [google_container_cluster.gke]
}

# ---------- Despliegue de la aplicación + pipeline con Helm ----------
data "google_client_config" "default" {}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.gke.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.gke.master_auth[0].cluster_ca_certificate)
  }
}

resource "helm_release" "otel_lab" {
  name             = "otel-lab"
  chart            = "${path.module}/../helm/otel-lab"
  namespace        = "observability"
  create_namespace = true

  # Autopilot tarda en aprovisionar nodos la primera vez
  timeout = 900
  wait    = true

  set {
    name  = "image.registry"
    value = "${var.region}-docker.pkg.dev/${var.project_id}/otel-lab"
  }

  set {
    name  = "collector.gcpServiceAccount"
    value = google_service_account.otel_collector.email
  }

  depends_on = [google_container_cluster.gke]
}
