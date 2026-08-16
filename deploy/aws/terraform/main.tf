terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

provider "aws" {
  region = var.region
}

# =============================================================================
# PERFIL COSTO CERO
# Solo se crean recursos gratuitos o de costo despreciable:
#   - ECS Fargate: se paga por segundo de vCPU/RAM; tasks mínimas y desired_count=1
#   - Sin ALB (ahorra ~0,0225 USD/h): service-a se expone con IP pública directa
#   - Sin Amazon Managed Prometheus (cobra desde la primera muestra): se usa una
#     task de Prometheus que scrapea el endpoint del Collector
#   - X-Ray: 100.000 trazas/mes gratis | CloudWatch Logs: 5 GB/mes gratis
#   - Cloud Map, ECR (500 MB), IAM, SSM Standard: sin costo en free tier
# Costo medido del laboratorio completo (~2 h): menos de 0,20 USD.
# =============================================================================

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---------- ECR: repositorios de imágenes ----------
resource "aws_ecr_repository" "service_a" {
  name         = "otel-lab/service-a"
  force_delete = true # permite `terraform destroy` sin vaciar el repo a mano
}

resource "aws_ecr_repository" "service_b" {
  name         = "otel-lab/service-b"
  force_delete = true
}

# Expira imágenes viejas para no superar los 500 MB gratuitos de ECR
resource "aws_ecr_lifecycle_policy" "service_a" {
  repository = aws_ecr_repository.service_a.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conservar solo la última imagen"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 1 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "service_b" {
  repository = aws_ecr_repository.service_b.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conservar solo la última imagen"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 1 }
      action       = { type = "expire" }
    }]
  })
}

# ---------- Cluster ECS ----------
# containerInsights se deja DESACTIVADO: genera métricas custom de CloudWatch
# que se cobran por encima de las 10 gratuitas.
resource "aws_ecs_cluster" "cluster" {
  name = "otel-lab"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

# ---------- Cloud Map (service discovery interno, sin costo relevante) ----------
resource "aws_service_discovery_private_dns_namespace" "ns" {
  name = "otel-lab.local"
  vpc  = data.aws_vpc.default.id
}

resource "aws_service_discovery_service" "service_a" {
  name = "service-a"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.ns.id
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

resource "aws_service_discovery_service" "service_b" {
  name = "service-b"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.ns.id
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

resource "aws_service_discovery_service" "postgres" {
  name = "postgres"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.ns.id
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

# ---------- IAM ----------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "otel-lab-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role" "task_role" {
  name               = "otel-lab-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "exec_policy" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Permite leer la configuración del Collector desde SSM al arrancar la task
resource "aws_iam_role_policy" "exec_ssm_read" {
  name = "otel-lab-ssm-read"
  role = aws_iam_role.task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters", "ssm:GetParameter"]
      Resource = [aws_ssm_parameter.otel_config.arn, aws_ssm_parameter.prometheus_config.arn]
    }]
  })
}

# Permisos del Collector en runtime: X-Ray (trazas) + CloudWatch Logs (logs)
resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.task_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "task_cw_logs" {
  name = "otel-lab-cw-logs"
  role = aws_iam_role.task_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "arn:aws:logs:*:*:*"
    }]
  })
}

# ---------- Configuraciones en SSM Parameter Store (tier Standard = gratis) ----------
resource "aws_ssm_parameter" "otel_config" {
  name  = "/otel-lab/collector-config"
  type  = "String"
  tier  = "Standard"
  value = file("${path.module}/../../../collector/otel-collector-aws.yaml")
}

resource "aws_ssm_parameter" "prometheus_config" {
  name = "/otel-lab/prometheus-config"
  type = "String"
  tier = "Standard"
  value = yamlencode({
    global = {
      scrape_interval = "15s"
    }
    scrape_configs = [
      {
        job_name      = "otel-collector-apps"
        honor_labels  = true
        static_configs = [{
          targets = [
            "service-a.otel-lab.local:8889",
            "service-b.otel-lab.local:8889",
          ]
        }]
      },
      {
        job_name = "otel-collector-internal"
        static_configs = [{
          targets = [
            "service-a.otel-lab.local:8888",
            "service-b.otel-lab.local:8888",
          ]
        }]
      },
    ]
  })
}

# ---------- CloudWatch Logs (retención corta para no pasar de 5 GB gratuitos) ----------
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/otel-lab/ecs"
  retention_in_days = 1
}

# ---------- Security group ----------
resource "aws_security_group" "svc" {
  name        = "otel-lab-svc"
  description = "Trafico interno del laboratorio y acceso publico a las UIs"
  vpc_id      = data.aws_vpc.default.id

  # Comunicación entre tasks dentro de la VPC (HTTP, OTLP, Postgres, scrape)
  ingress {
    description = "Trafico interno de la VPC"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  # Acceso a service-a y a la UI de Prometheus desde tu equipo.
  # Restringe `admin_cidr` a tu IP pública para no exponerlo a internet.
  ingress {
    description = "API de service-a"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "UI de Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "Salida a internet (pull de imagenes, X-Ray, CloudWatch)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
