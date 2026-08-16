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
sidecar en ECS Fargate (trazas → X-Ray, métricas → Prometheus, logs → CloudWatch).

## Estructura del repositorio

```
services/service-a/        # Órdenes: FastAPI + httpx (auto-instr) + custom span orders.calculate_total
services/service-b/        # Inventario: FastAPI + SQLAlchemy/Postgres (auto-instr) + custom span inventory.check_stock
collector/                 # Config OTel Collector: local, GCP (GKE) y AWS (ECS)
deploy/local/              # docker-compose con todo el stack + Grafana aprovisionada
deploy/gcp/terraform/      # GKE Autopilot + Artifact Registry + Workload Identity + presupuesto
deploy/gcp/helm/otel-lab/  # Chart: apps + Collector + Jaeger
deploy/aws/terraform/      # ECS Fargate + X-Ray + CloudWatch + Prometheus + ADOT sidecar + presupuesto
scripts/                   # Despliegue y destrucción automatizados de ambas nubes
benchmark/                 # k6 (75 VUs, 5 min) + monitor de CPU/RAM + resultados
docs/                      # Reporte técnico PDF + runbook costo cero + capturas
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

## Despliegue en las dos nubes — perfil costo cero

La IaC está afinada para no generar costo: cluster GKE **Autopilot** (cubierto por
el crédito mensual del free tier de GKE), **sin balanceadores** en ninguna de las dos nubes,
**sin Amazon Managed Prometheus**, tasks de Fargate mínimas y retención de logs corta.
Una sesión de laboratorio de ~2 horas en ambas nubes cuesta menos de 0,35 USD, cubiertos
por los créditos gratuitos.

**El procedimiento completo, con capturas a tomar y checklist de cierre, está en
[`docs/RUNBOOK-costo-cero.md`](docs/RUNBOOK-costo-cero.md).** Resumen:

```bash
# GCP: habilita APIs, crea el cluster, publica imágenes y despliega el chart
bash scripts/gcp-deploy.sh TU_PROYECTO us-central1
bash scripts/gcp-destroy.sh TU_PROYECTO us-central1   # al terminar

# AWS: crea ECR, publica imágenes, despliega ECS y muestra las IPs públicas
bash scripts/aws-deploy.sh us-east-1
bash scripts/aws-destroy.sh us-east-1                   # al terminar
```

Los scripts de `destroy` verifican que no quede ningún recurso facturando.
Para activar las alertas de presupuesto (recomendado), pasa
`-var billing_account_id=...` en GCP y `-var budget_alert_email=...` en AWS.

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

Para generar tráfico sostenido mientras se capturan evidencias en la nube (carga
moderada, con un 10 % de peticiones fallidas a propósito para poblar el panel de
errores y dejar trazas de caso negativo):

```bash
k6 run benchmark/cloud-traffic.js                                  # GCP, vía port-forward
TARGET_URL=http://IP_SERVICE_A:8000 k6 run benchmark/cloud-traffic.js   # AWS, IP pública
```

## Los tres pilares — dónde mirar

| Pilar    | Emisión (SDK)                                    | Transporte | Backend local | GCP | AWS |
|----------|--------------------------------------------------|-----------|---------------|-----|-----|
| Trazas   | Auto-instr FastAPI/HTTPX/SQLAlchemy + custom spans | OTLP gRPC | Jaeger        | Jaeger (GKE) | X-Ray |
| Métricas | Counters/histogramas custom + http.server.duration | OTLP gRPC | Prometheus    | Prometheus | Prometheus en ECS |
| Logs     | JSON con `trace_id`/`span_id` inyectados          | OTLP gRPC | Loki          | Cloud Logging | CloudWatch |
