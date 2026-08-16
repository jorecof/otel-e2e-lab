# Red de seguridad: alerta cuando el gasto del proyecto supera el umbral.
# Los presupuestos de GCP no tienen costo. Solo se crea si se define
# `billing_account_id` (obtenlo con: gcloud billing accounts list).

resource "google_billing_budget" "lab" {
  count = var.billing_account_id == "" ? 0 : 1

  billing_account = var.billing_account_id
  display_name    = "otel-lab-budget"

  budget_filter {
    projects = ["projects/${var.project_id}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_limit_usd)
    }
  }

  # Avisos al 50 %, 90 % y 100 % del umbral
  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 0.9
  }

  threshold_rules {
    threshold_percent = 1.0
  }
}
