terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

provider "aws" {
  region = var.region
}

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
resource "aws_ecr_repository" "service_a" { name = "otel-lab/service-a" }
resource "aws_ecr_repository" "service_b" { name = "otel-lab/service-b" }

# ---------- Cluster ECS ----------
resource "aws_ecs_cluster" "cluster" {
  name = "otel-lab"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ---------- Cloud Map (service discovery interno) ----------
resource "aws_service_discovery_private_dns_namespace" "ns" {
  name = "otel-lab.local"
  vpc  = data.aws_vpc.default.id
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
resource "aws_iam_role" "task_execution" {
  name               = "otel-lab-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role" "task_role" {
  name               = "otel-lab-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "exec_policy" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Permisos del Collector: X-Ray (trazas), CloudWatch Logs (logs), AMP (métricas)
resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.task_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy_attachment" "cw_logs" {
  role       = aws_iam_role.task_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_role_policy_attachment" "amp_write" {
  role       = aws_iam_role.task_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess"
}

# ---------- Amazon Managed Prometheus ----------
resource "aws_prometheus_workspace" "amp" {
  alias = "otel-lab"
}

# ---------- Configuración del Collector en SSM ----------
resource "aws_ssm_parameter" "otel_config" {
  name  = "/otel-lab/collector-config"
  type  = "String"
  tier  = "Advanced"
  value = file("${path.module}/../../../collector/otel-collector-aws.yaml")
}

# ---------- Security group ----------
resource "aws_security_group" "svc" {
  name   = "otel-lab-svc"
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
