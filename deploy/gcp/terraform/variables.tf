variable "project_id" {
  description = "ID del proyecto GCP"
  type        = string
}

variable "region" {
  description = <<-EOT
    Región del cluster y de Artifact Registry. GKE Autopilot solo admite
    ubicaciones regionales; el crédito del free tier de GKE (74,40 USD/mes)
    cubre un cluster Autopilot al mes.
  EOT
  type        = string
  default     = "us-central1"
}

variable "billing_account_id" {
  description = "ID de la cuenta de facturación para crear la alerta de presupuesto. Vacío = no se crea."
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "Umbral del presupuesto mensual en USD"
  type        = number
  default     = 1
}
