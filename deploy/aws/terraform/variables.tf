variable "region" {
  description = "Región AWS"
  type        = string
  default     = "us-east-1"
}

variable "admin_cidr" {
  description = <<-EOT
    CIDR autorizado para llegar a service-a (8000) y a la UI de Prometheus (9090).
    Usa tu IP pública en formato x.x.x.x/32 — obtenla con: curl -s ifconfig.me
    El valor por defecto (0.0.0.0/0) deja las UIs abiertas a internet: cámbialo.
  EOT
  type        = string
  default     = "0.0.0.0/0"
}

variable "budget_limit_usd" {
  description = "Umbral del presupuesto mensual de AWS Budgets (alerta por correo)"
  type        = string
  default     = "1"
}

variable "budget_alert_email" {
  description = "Correo que recibe la alerta de presupuesto. Vacío = no se crea el presupuesto."
  type        = string
  default     = ""
}
