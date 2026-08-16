# LAB: Pipeline OpenTelemetry End-to-End — Jaeger + Prometheus en GCP y AWS

Pipeline de observabilidad completo basado en **OpenTelemetry** que captura los tres
pilares — **métricas** (Prometheus), **logs estructurados** (JSON + Loki/CloudWatch)
y **trazas distribuidas** (Jaeger/X-Ray) — desde dos microservicios FastAPI, con
**correlación cross-signal vía `trace_id`** (W3C TraceContext).

## Arquitectura

```
                 ┌────────────┐  HTTP (traceparent W3C)  ┌────────────┐   SQL    ┌──────────┐
  k6 (carga) ───▶│ service-a  │─────────────────────────▶│ service-b  │─────────▶│ Postgres │
                 │  (orders)  │                          │(inventory) │          └──────────┘
                 └─────┬──────┘                          └─────┬──────┘
                       │  OTLP gRPC (trazas+métricas+logs)     │
                       └────────────────┬──────────────────────┘
                                ┌───────▼────────┐
                                │ OTel Collector │  memory_limiter → resource → batch
                                └───┬────┬───┬───┘
                          trazas ───┘    │   └─── logs
                        ┌───────┐  ┌─────▼─────┐  ┌──────┐
                        │Jaeger │  │Prometheus │  │ Loki │──┐
                        └───┬───┘  └─────┬─────┘  └──┬───┘  │
                            └──────────┐ │ ┌─────────┘      │
                                    ┌──▼─▼─▼──┐             │
                                    │ Grafana │◀── pivot por trace_id
                                    └─────────┘
```

En **GCP** el Collector corre en GKE (logs → Cloud Logging); en **AWS** corre como
sidecar en ECS Fargate (trazas → X-Ray, métricas → AMP, logs → CloudWatch).

## Estructura del repositorio

```
services/service-a/        # Órdenes: FastAPI + httpx (auto-instr) + custom span orders.calculate_total
services/service-b/        # Inventario: FastAPI + SQLAlchemy/Postgres (auto-instr) + custom span inventory.check_stock
collector/                 # Config OTel Collector: local, GCP (GKE) y AWS (ECS)
deploy/local/              # docker-compose con todo el stack + Grafana aprovisionada
deploy/gcp/terraform/      # GKE Autopilot + Artifact Registry + Workload Identity
deploy/gcp/helm/otel-lab/  # Chart: apps + Collector + Jaeger
deploy/aws/terraform/      # ECS Fargate + ALB + X-Ray + AMP + CloudWatch + ADOT sidecar
benchmark/                 # k6 (75 VUs, 5 min) + monitor de CPU/RAM + resultados
docs/                      # Reporte técnico PDF + capturas
```

## Ejecución local (5 minutos)

```bash
cd deploy/local
docker compose up -d --build
# Tráfico de prueba
for i in $(seq 1 50); do curl -s "localhost:8000/api/orders/$((RANDOM%5+1))?qty=$((RANDOM%10+1))" > /dev/null; done
```

| UI          | URL                    |
|-------------|------------------------|
| Jaeger      | http://localhost:16686 |
| Grafana     | http://localhost:3000  (dashboard "OTel Lab — SLIs" aprovisionado) |
| Prometheus  | http://localhost:9090  |
| service-a   | http://localhost:8000/api/orders/1?qty=2 |

**Correlación cross-signal:** en Grafana → Explore → Loki, consulta
`{service_name="service-a"}`; cada log muestra su `trace_id` y el derived field
**TraceID** abre la traza correspondiente en Jaeger (mismo `trace_id` en los 3 pilares).

## Despliegue GCP (GKE)

```bash
# 1. Construir y subir imágenes
gcloud auth configure-docker us-central1-docker.pkg.dev
docker build -t us-central1-docker.pkg.dev/$PROJECT/otel-lab/service-a:1.0.0 services/service-a && docker push ...
docker build -t us-central1-docker.pkg.dev/$PROJECT/otel-lab/service-b:1.0.0 services/service-b && docker push ...
# 2. Infraestructura + despliegue
cd deploy/gcp/terraform
terraform init && terraform apply -var project_id=$PROJECT
```

## Despliegue AWS (ECS Fargate)

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.us-east-1.amazonaws.com
docker build -t $ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/otel-lab/service-a:1.0.0 services/service-a && docker push ...
docker build -t $ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/otel-lab/service-b:1.0.0 services/service-b && docker push ...
cd deploy/aws/terraform
terraform init && terraform apply
```

## Benchmark de overhead

```bash
cd benchmark
# Línea base (sin instrumentación)
OTEL_ENABLED=false docker compose -f ../deploy/local/docker-compose.yaml up -d --force-recreate service-a service-b
k6 run --summary-export results/k6_baseline.json load-test.js
# Con OTel
OTEL_ENABLED=true docker compose -f ../deploy/local/docker-compose.yaml up -d --force-recreate service-a service-b
k6 run --summary-export results/k6_otel.json load-test.js
```

Resultados medidos en `benchmark/results/` y análisis completo en
`docs/reporte-tecnico.pdf`.

## Los tres pilares — dónde mirar

| Pilar    | Emisión (SDK)                                    | Transporte | Backend local | GCP | AWS |
|----------|--------------------------------------------------|-----------|---------------|-----|-----|
| Trazas   | Auto-instr FastAPI/HTTPX/SQLAlchemy + custom spans | OTLP gRPC | Jaeger        | Jaeger (GKE) | X-Ray |
| Métricas | Counters/histogramas custom + http.server.duration | OTLP gRPC | Prometheus    | Prometheus | AMP |
| Logs     | JSON con `trace_id`/`span_id` inyectados          | OTLP gRPC | Loki          | Cloud Logging | CloudWatch |
