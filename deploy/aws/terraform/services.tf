# Task definitions: cada servicio corre con el OTel Collector como SIDECAR.
# El SDK exporta a localhost:4317 y el sidecar reenvía a X-Ray / AMP / CloudWatch.

locals {
  collector_sidecar = {
    name      = "otel-collector"
    image     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.42.0"
    essential = true
    secrets = [
      { name = "AOT_CONFIG_CONTENT", valueFrom = aws_ssm_parameter.otel_config.arn }
    ]
    environment = [
      { name = "AWS_REGION", value = var.region },
      { name = "AMP_REMOTE_WRITE_URL", value = "${aws_prometheus_workspace.amp.prometheus_endpoint}api/v1/remote_write" }
    ]
    portMappings = [
      { containerPort = 4317, protocol = "tcp" },
      { containerPort = 4318, protocol = "tcp" }
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
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/otel-lab/ecs"
  retention_in_days = 7
}

# ---------- PostgreSQL (contenedor de laboratorio) ----------
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
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.svc.id]
    assign_public_ip = true
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
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.svc.id]
    assign_public_ip = true
  }
  service_registries {
    registry_arn = aws_service_discovery_service.service_b.arn
  }
}

# ---------- service-a + sidecar + ALB ----------
resource "aws_lb" "alb" {
  name               = "otel-lab-alb"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.svc.id]
}

resource "aws_lb_target_group" "service_a" {
  name        = "otel-lab-service-a"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"
  health_check {
    path = "/health"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service_a.arn
  }
}

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
  desired_count   = 2
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.svc.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.service_a.arn
    container_name   = "service-a"
    container_port   = 8000
  }
  depends_on = [aws_lb_listener.http]
}
