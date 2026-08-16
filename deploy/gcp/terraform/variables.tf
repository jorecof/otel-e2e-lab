variable "project_id" {
  description = "ID del proyecto GCP"
  type        = string
}

variable "region" {
  description = "Región de despliegue"
  type        = string
  default     = "us-central1"
}
