variable "project_id" {
  description = "ID del proyecto GCP"
  type        = string
}

variable "region" {
  description = "Región (usada por Artifact Registry)"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = <<-EOT
    Zona del cluster. DEBE ser una zona (no una región): el crédito del free tier
    de GKE solo cubre clusters zonales o Autopilot, nunca regionales.
  EOT
  type        = string
  default     = "us-central1-a"
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
