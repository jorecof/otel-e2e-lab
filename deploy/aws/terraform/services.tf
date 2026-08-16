# Task definitions: cada servicio corre con el OTel Collector como SIDECAR.
# El SDK exporta a localhost:4317 y el sidecar reenvía a X-Ray y CloudWatch,
# y expone las métricas en :8889 para que las scrapee la task de Prometheus.
#
# Perfil costo cero: 512 CPU units (0,5 vCPU) / 1024 MB por task de aplicación,
# desired_count = 1, y sin balanceador (IP pública directa).

locals {
  # Sidecar ADOT reutilizado por service-a y service-b
  collector_sidecar = {
    name      = "otel-collector"
    image     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.42.0"
    essential = true
    cpu       = 128
    memory    = 256
    secrets = [
      { name = "AOT_CONFIG_CONTENT", valueFrom = aws_ssm_parameter.otel_config.arn }
    ]
    environment = [
      { name = "AWS_REGION", value = var.region }
    ]
    portMappings = [
      { containerPort = 4317, protocol = "tcp" },
      { containerPort = 4318, protocol = "tcp" },
      { containerPort = 8889, protocol = "tcp" },
      { containerPort = 8888, protocol = "tcp" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "otel-collector"
      }
    }
  }

  network = {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.svc.id]
    assign_public_ip = true # necesario en subredes públicas para hacer pull de imágenes
  }
}

# ---------- PostgreSQL (contenedor de laboratorio, no RDS: RDS no es gratis aquí) ----------
resource "aws_ecs_task_definition" "postgres" {
  family                   = "otel-lab-postgres"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "postgres"
      image     = "public.ecr.aws/docker/library/postgres:16-alpine"
      essential = true
      environment = [
        { name = "POSTGRES_USER", value = "otel" },
        { name = "POSTGRES_PASSWORD", value = "otel" },
        { name = "POSTGRES_DB", value = "inventory" }
      ]
      portMappings = [{ containerPort = 5432, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "postgres"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "postgres" {
  name            = "postgres"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.postgres.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.network.subnets
    security_groups  = local.network.security_groups
    assign_public_ip = local.network.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.postgres.arn
  }
}

# ---------- service-b + sidecar ----------
resource "aws_ecs_task_definition" "service_b" {
  family                   = "otel-lab-service-b"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role.arn

  container_definitions = jsonencode([
    {
      name      = "service-b"
      image     = "${aws_ecr_repository.service_b.repository_url}:1.0.0"
      essential = true
      cpu       = 384
      memory    = 768
      environment = [
        { name = "OTEL_ENABLED", value = "true" },
        { name = "OTEL_SERVICE_NAME", value = "service-b" },
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
        { name = "DATABASE_URL", value = "postgresql+psycopg2://otel:otel@postgres.otel-lab.local:5432/inventory" },
        { name = "DEPLOY_ENV", value = "ecs-fargate" }
      ]
      portMappings = [{ containerPort = 8001, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "service-b"
        }
      }
    },
    local.collector_sidecar
  ])
}

resource "aws_ecs_service" "service_b" {
  name            = "service-b"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.service_b.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.network.subnets
    security_groups  = local.network.security_groups
    assign_public_ip = local.network.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.service_b.arn
  }

  depends_on = [aws_ecs_service.postgres]
}

# ---------- service-a + sidecar (expuesto con IP pública, sin ALB) ----------
resource "aws_ecs_task_definition" "service_a" {
  family                   = "otel-lab-service-a"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role.arn

  container_definitions = jsonencode([
    {
      name      = "service-a"
      image     = "${aws_ecr_repository.service_a.repository_url}:1.0.0"
      essential = true
      cpu       = 384
      memory    = 768
      environment = [
        { name = "OTEL_ENABLED", value = "true" },
        { name = "OTEL_SERVICE_NAME", value = "service-a" },
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
        { name = "SERVICE_B_URL", value = "http://service-b.otel-lab.local:8001" },
        { name = "DEPLOY_ENV", value = "ecs-fargate" }
      ]
      portMappings = [{ containerPort = 8000, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "service-a"
        }
      }
    },
    local.collector_sidecar
  ])
}

resource "aws_ecs_service" "service_a" {
  name            = "service-a"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.service_a.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.network.subnets
    security_groups  = local.network.security_groups
    assign_public_ip = local.network.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.service_a.arn
  }

  depends_on = [aws_ecs_service.service_b]
}

# ---------- Prometheus (reemplaza a AMP: mismo resultado, costo cero) ----------
# La configuración llega por variable de entorno desde SSM y se escribe al
# arrancar; así no hace falta construir ni publicar una imagen propia.
resource "aws_ecs_task_definition" "prometheus" {
  family                   = "otel-lab-prometheus"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([
    {
      name       = "prometheus"
      # Registro oficial del proyecto Prometheus (quay.io): `prom/prometheus` no
      # es imagen oficial de Docker, así que NO existe en public.ecr.aws/docker/library.
      image      = "quay.io/prometheus/prometheus:v3.1.0"
      essential  = true
      entryPoint = ["/bin/sh", "-c"]
      command = [
        "printf '%s' \"$PROM_CONFIG\" > /tmp/prometheus.yml && /bin/prometheus --config.file=/tmp/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=2h"
      ]
      secrets = [
        { name = "PROM_CONFIG", valueFrom = aws_ssm_parameter.prometheus_config.arn }
      ]
      portMappings = [{ containerPort = 9090, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "prometheus"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "prometheus" {
  name            = "prometheus"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.network.subnets
    security_groups  = local.network.security_groups
    assign_public_ip = local.network.assign_public_ip
  }

  depends_on = [aws_ecs_service.service_a]
}
