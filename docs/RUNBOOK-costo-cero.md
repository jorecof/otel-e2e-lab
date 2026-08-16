# Runbook: desplegar en GCP y AWS con costo cero

Objetivo: cumplir el criterio "Collector desplegado en **ambas** clouds" (1.25 pts)
sin pagar nada de tu bolsillo. La estrategia tiene tres partes: **usar los créditos
gratuitos**, **eliminar los recursos caros** y **destruir todo el mismo día**.

---

## 1. Lo que realmente cuesta y cómo se neutraliza

| Recurso | Costo normal | Qué se hizo |
|---|---|---|
| GKE — tarifa de gestión | 0,10 USD/h | Cluster **Autopilot**: el free tier de GKE abona 74,40 USD/mes (equivale a un cluster Autopilot), que la cubre entera. Autopilot siempre es regional: la API rechaza clusters zonales |
| GKE — recursos de pods | ~0,0445 USD/vCPU-h | 1 réplica por servicio (7 pods: apps, Postgres, Collector, Jaeger, Prometheus, Grafana), requests mínimos de Autopilot → ~0,095 USD/h |
| Balanceador de Google | ~0,025 USD/h por regla | **Eliminado**: Services en ClusterIP + `kubectl port-forward` (gratis) |
| AWS ALB | ~0,0225 USD/h + LCU | **Eliminado**: IP pública directa en la task de service-a |
| Amazon Managed Prometheus | cobra desde la 1.ª muestra | **Eliminado**: una task de Prometheus scrapea el endpoint del Collector |
| ECS Fargate | ~0,04 USD/vCPU-h | 4 tasks pequeñas, `desired_count=1` → ~0,074 USD/h |
| AWS X-Ray | 5 USD/millón de trazas | Free tier: **100.000 trazas/mes** gratis (el laboratorio usa unos cientos) |
| CloudWatch Logs | 0,50 USD/GB | Free tier: **5 GB/mes**; retención puesta en 1 día |
| Cloud Logging | 0,50 USD/GiB | Free tier: **50 GiB/mes por proyecto** |
| ECR / Artifact Registry | por GB-mes | Política de ciclo de vida: solo se conserva la última imagen |

**Costo real estimado de una sesión de ~2 horas en ambas nubes: menos de 0,35 USD**,
y ese monto se descuenta de los créditos gratuitos, no de tu tarjeta.

### Créditos disponibles (verificado en agosto de 2026)

- **Google Cloud**: 300 USD en créditos para cuentas nuevas, más el crédito mensual de
  GKE (74,40 USD) que cubre un cluster Autopilot o un zonal Standard al mes.
- **AWS**: desde julio de 2025 el free tier da **100 USD al registrarse y hasta 100 USD
  adicionales** por usar ciertos servicios (200 USD en total). El plan gratuito dura
  6 meses o hasta agotar los créditos, lo que ocurra primero.

Si tu universidad participa en programas educativos (GitHub Student Developer Pack,
Google Cloud for Education, AWS Academy), revisa si tienes créditos adicionales.

---

## 2. Antes de empezar: las dos redes de seguridad

Configúralas primero. Toman dos minutos y evitan cualquier sorpresa.

```bash
# --- GCP: alerta de presupuesto a 1 USD ---
gcloud billing accounts list          # copia el ACCOUNT_ID
cd deploy/gcp/terraform
# se aplicará junto con el resto pasando:
#   -var billing_account_id=XXXXXX-XXXXXX-XXXXXX

# --- AWS: alerta de presupuesto a 1 USD ---
cd deploy/aws/terraform
# pasa tu correo al aplicar:
#   -var budget_alert_email=tucorreo@ejemplo.com
```

Además, en la consola de facturación de GCP **no actives la cuenta de pago completa**
hasta agotar los 300 USD: mientras estés en el trial, Google no cobra nada.

---

## 3. Despliegue en GCP (~15 min)

Requisitos: `gcloud`, `terraform`, `kubectl`, `helm` y Docker corriendo.

```bash
gcloud auth login
gcloud config set project TU_PROYECTO
bash scripts/gcp-deploy.sh TU_PROYECTO us-central1
```

El script habilita APIs, crea el cluster, publica las imágenes, despliega el chart
y espera a que los pods estén listos. Al terminar imprime los comandos de acceso.

**Capturas para el informe:**

Abre los túneles en puertos locales distintos a los del stack local, para no
confundir un entorno con el otro al capturar:

```bash
kubectl -n observability port-forward svc/service-a 8080:8000 &
kubectl -n observability port-forward svc/jaeger-ui 16687:16686 &
kubectl -n observability port-forward svc/grafana   3001:3000 &
kubectl -n observability port-forward svc/prometheus 9091:9090 &
```

Genera tráfico sostenido con k6 mientras tomas las capturas (déjalo corriendo
en su propia pestaña; 10 minutos por defecto):

```bash
k6 run benchmark/cloud-traffic.js
```

1. **Jaeger en GKE** → `http://localhost:16686`, busca `service-a`, abre una traza
   completa. Captura la vista de timeline con los 11 spans.
2. **Grafana en GKE** → `http://localhost:3000`, carpeta "OTel Lab", dashboard
   "SLIs y salud del pipeline". Captura los 6 paneles con datos reales del cluster.
3. **Cloud Logging** → consola de GCP → Logging → consulta
   `logName="projects/TU_PROYECTO/logs/otel-lab"`. Expande una entrada y muestra el
   campo `trace_id`: esa es la evidencia de correlación en GCP.
4. **Pods corriendo** → `kubectl -n observability get pods -o wide` (captura de terminal).

**Destruye cuando termines:**

```bash
bash scripts/gcp-destroy.sh TU_PROYECTO us-central1
```

---

## 4. Despliegue en AWS (~12 min)

Requisitos: `aws` CLI configurado (`aws configure`), `terraform` y Docker.

```bash
bash scripts/aws-deploy.sh us-east-1
```

El script detecta tu IP pública y restringe los puertos 8000 y 9090 a ella, crea ECR,
publica las imágenes, despliega ECS y espera a que las tasks estén estables. Termina
imprimiendo las IPs públicas.

**Capturas para el informe:**

```bash
bash scripts/aws-endpoints.sh us-east-1     # vuelve a imprimir las IPs
TARGET_URL=http://IP_SERVICE_A:8000 k6 run benchmark/cloud-traffic.js
```

1. **X-Ray** → consola → CloudWatch → X-Ray traces. Abre una traza y captura el mapa
   de servicios (`service-a` → `service-b`) y la línea de tiempo de spans.
2. **CloudWatch Logs** → grupo `/otel-lab/ecs`. Filtra por un trace_id concreto:
   `{ $.trace_id = "PEGA_EL_TRACE_ID" }`. Captura los logs de ambos servicios
   compartiendo el mismo id.
3. **Prometheus en ECS** → `http://IP_PROMETHEUS:9090/graph`, ejecuta
   `histogram_quantile(0.99, sum by (le, job) (rate(http_server_duration_milliseconds_bucket[5m])))`.
4. **Tasks corriendo** → consola de ECS, cluster `otel-lab` (captura de las 4 tasks).

**Destruye cuando termines:**

```bash
bash scripts/aws-destroy.sh us-east-1
```

---

## 5. Checklist de cierre

Ejecuta esto al final del día. Los scripts de destroy ya lo verifican, pero confírmalo
tú mismo en las consolas:

- [ ] `gcloud container clusters list` → vacío
- [ ] `gcloud compute forwarding-rules list` → vacío (ningún balanceador olvidado)
- [ ] `aws ecs list-services --cluster otel-lab` → vacío o cluster inexistente
- [ ] `aws elbv2 describe-load-balancers` → vacío
- [ ] `aws amp list-workspaces` → vacío (AMP cobra aunque no se use)
- [ ] Facturación de GCP y AWS revisada al día siguiente (los cargos aparecen con retraso)

---

## 6. Problemas frecuentes

**"Los pods de GKE quedan en Pending"** — Autopilot tarda 2-5 minutos en aprovisionar
nodos la primera vez. Si pasan 10 minutos, revisa `kubectl -n observability describe pod`:
suele ser que los requests no cumplen el mínimo de Autopilot (250m CPU / 512Mi).

**"Los pods de service-a/service-b quedan en ImagePullBackOff con 403 Forbidden"** —
el cluster no tiene permiso para leer Artifact Registry. Los nodos de GKE usan la Service
Account por defecto de Compute Engine, que en proyectos creados desde 2024 ya no recibe el
rol Editor automáticamente. La IaC lo concede con `google_project_iam_member.gke_nodes_artifact_reader`;
si necesitas aplicarlo a mano:
```bash
PROJNUM=$(gcloud projects describe TU_PROYECTO --format='value(projectNumber)')
gcloud projects add-iam-policy-binding TU_PROYECTO \
  --member="serviceAccount:${PROJNUM}-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader" --condition=None
```

**"kubectl falla con gke-gcloud-auth-plugin not found"** — instálalo con
`gcloud components install gke-gcloud-auth-plugin` y asegúrate de que el `bin` del SDK esté
en el PATH: `export PATH="$(gcloud info --format='value(installation.sdk_root)')/bin:$PATH"`.

**"La task de ECS se reinicia en bucle"** — mira los logs en CloudWatch, grupo
`/otel-lab/ecs`. Las causas típicas son que la imagen no se publicó en ECR, o que
`service-b` arrancó antes que Postgres (basta esperar, hay reintentos).

**"Error de rate limit al bajar imágenes"** — Docker Hub limita las descargas anónimas.
Las imágenes del laboratorio usan registros sin límite (`public.ecr.aws` y `quay.io`)
salvo el chart de GKE; si te topas con el límite ahí, haz `docker login` con tu cuenta
de Docker Hub antes de desplegar.

**"No puedo acceder a la IP pública de AWS"** — el security group solo permite tu IP.
Si cambiaste de red, vuelve a aplicar: `terraform apply -var admin_cidr=$(curl -s ifconfig.me)/32`.

**Construyes desde un Mac con Apple Silicon** — los scripts ya pasan
`--platform linux/amd64` al `docker build`; si compilas a mano, no lo olvides o las
tasks fallarán con "exec format error".
