# Red de seguridad: alerta por correo si el gasto del mes supera el umbral.
# AWS Budgets es gratuito para los dos primeros presupuestos de la cuenta.
# Solo se crea si se define `budget_alert_email`.

resource "aws_budgets_budget" "lab" {
  count = var.budget_alert_email == "" ? 0 : 1

  name         = "otel-lab-budget"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Avisa cuando el gasto real llega al 50 % del umbral
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # Y también cuando la proyección del mes lo supera, para reaccionar antes
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
