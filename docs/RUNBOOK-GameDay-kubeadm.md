# Runbook — Ejecutar el Game Day sobre el cluster kubeadm (3 nodos, arm64)

Destino: cluster `kube-cp` 192.168.0.20 / `kube-w1` .21 / `kube-w2` .22
(Debian 12 arm64, Kubernetes v1.35, containerd 2.3.3, Calico v3.32.1, pod CIDR 10.244.0.0/16).

Este cluster es **mejor banco de pruebas que Docker Compose**: hay tres kubelets reales, un CNI
real y programación real, así que los experimentos de caos miden resiliencia de verdad y no de
un solo daemon de contenedores.

Todo lo que sigue se ejecuta desde el Mac salvo donde diga "en el nodo".

---

## Fase 0 — Preparar el acceso desde el Mac (una sola vez)

```bash
scp kubernet@192.168.0.20:/etc/kubernetes/admin.conf ~/.kube/config-lab
export KUBECONFIG=~/.kube/config-lab
kubectl get nodes -o wide          # los tres deben decir Ready
```

Si `admin.conf` no es legible por tu usuario, cópialo primero con `sudo cat` en el nodo.

**Libera el control-plane para el laboratorio.** Los dos workers suman 4 GB y el stack son siete
pods; sin esto no cabe:

```bash
kubectl taint nodes kube-cp node-role.kubernetes.io/control-plane:NoSchedule-
```

---

## Fase 1 — Añadir la caja de herramientas de caos a las imágenes

Los experimentos necesitan `tc`, `iptables` y `stress-ng` **dentro** de los contenedores. Añade
esta capa a `services/service-a/Dockerfile` y `services/service-b/Dockerfile`, justo debajo del
`FROM`:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
        iproute2 iptables stress-ng procps \
    && rm -rf /var/lib/apt/lists/*
```

Es deuda deliberada de laboratorio: en producción esas herramientas no van en la imagen de la
aplicación, van en un pod de caos con RBAC propio (que es justo lo que hace LitmusChaos).

---

## Fase 2 — Construir y llevar las imágenes al cluster (sin registry)

Tu Mac es arm64 y los nodos también, así que un `docker build` normal ya produce la arquitectura
correcta. No hay registry, así que las imágenes viajan por `scp` y se importan en containerd.

```bash
cd ~/otel-e2e-lab
docker build -t otel-lab/service-a:1.0.0 services/service-a
docker build -t otel-lab/service-b:1.0.0 services/service-b
docker save otel-lab/service-a:1.0.0 otel-lab/service-b:1.0.0 -o /tmp/lab-images.tar

for N in 192.168.0.20 192.168.0.21 192.168.0.22; do
  scp /tmp/lab-images.tar kubernet@$N:/tmp/
  ssh kubernet@$N 'sudo ctr -n k8s.io images import /tmp/lab-images.tar && rm /tmp/lab-images.tar'
done
```

`-n k8s.io` es obligatorio: es el namespace de containerd donde el kubelet busca las imágenes.
Sin eso la importación funciona y el pod se queda igualmente en `ErrImagePull`.

Verifica en un nodo: `sudo crictl images | grep otel-lab`.

---

## Fase 3 — Desplegar el chart

El chart de `deploy/gcp/helm/otel-lab` ya trae todo (Postgres, Collector, Jaeger, Prometheus,
Grafana). Solo hay que apuntarlo a las imágenes locales y bajar las peticiones de recursos, que
están dimensionadas para GKE Autopilot:

```bash
helm upgrade --install otel-lab deploy/gcp/helm/otel-lab \
  --namespace otel-lab --create-namespace \
  --set image.registry=otel-lab \
  --set image.tag=1.0.0 \
  --set image.pullPolicy=IfNotPresent \
  --set service.type=NodePort \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=256Mi

kubectl -n otel-lab get pods -w        # los 7 pods deben quedar Running
```

`pullPolicy=IfNotPresent` es imprescindible: el valor del chart es `Always` y con eso el kubelet
intentaría bajar `otel-lab/service-a` de Docker Hub y fallaría.

**Capacidad NET_ADMIN y límite de CPU** (necesarios para E1, E2 y el radio de impacto de E2):

```bash
kubectl -n otel-lab patch deploy service-a --type=json -p='[
 {"op":"add","path":"/spec/template/spec/containers/0/securityContext",
  "value":{"capabilities":{"add":["NET_ADMIN"]}}}]'

kubectl -n otel-lab patch deploy service-b --type=json -p='[
 {"op":"add","path":"/spec/template/spec/containers/0/securityContext",
  "value":{"capabilities":{"add":["NET_ADMIN"]}}},
 {"op":"add","path":"/spec/template/spec/containers/0/resources/limits",
  "value":{"cpu":"1","memory":"512Mi"}}]'

kubectl -n otel-lab rollout status deploy/service-a deploy/service-b
```

**Accesos.** service-a queda en NodePort (el generador de carga lo ataca por la LAN, como un
cliente real); las UIs por port-forward:

```bash
kubectl -n otel-lab get svc service-a -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
# -> por ejemplo 31234 ; la URL de carga es http://192.168.0.20:31234

kubectl -n otel-lab port-forward svc/prometheus 9090:9090 &
kubectl -n otel-lab port-forward svc/jaeger-ui  16686:16686 &
kubectl -n otel-lab port-forward svc/grafana    3000:3000 &
```

Prueba de humo:

```bash
curl -s "http://192.168.0.20:31234/api/orders/3?qty=2"
```

---

## Fase 4 — Estado estable (línea base)

Descomprime el kit de caos dentro del repo y mide la línea base **antes** de romper nada:

```bash
mkdir -p chaos && tar xzf ~/Downloads/chaos-gameday-kit.tar.gz -C chaos
pip3 install httpx matplotlib
export TARGET=http://192.168.0.20:31234

python3 chaos/loadgen.py --url $TARGET --rps 40 --duration 120 \
        --out chaos/results/baseline.csv
```

Anota p50/p95/p99 y disponibilidad: son los números contra los que se contrastan las hipótesis.
En el Game Day documentado la línea base fue p95 = 21,9 ms con 100 % de disponibilidad; sobre tu
cluster serán algo más altos porque hay red física de por medio.

---

## Fase 5 — Los tres experimentos

En los tres: arranca primero el generador de carga en segundo plano, y solo después inyecta.
Con la carga corriendo, `watch kubectl -n otel-lab top pods` es un buen segundo monitor.

### E1 — Latencia de red (hipótesis H1)

`tc netem` dentro del pod de service-a, filtrado por puerto destino 8001 para que el radio de
impacto sea **solo** la llamada a inventario y no el tráfico OTLP ni el DNS:

```bash
A=$(kubectl -n otel-lab get pod -l app=service-a -o name | head -1)
K="kubectl -n otel-lab exec $A --"

# comprobación previa: el kernel de Debian 12 debe traer sch_netem
$K tc qdisc add dev eth0 root netem delay 100ms && $K tc qdisc del dev eth0 root \
  && echo "netem disponible"

# INYECCIÓN — fase 1: 400 ms ± 100 ms
$K tc qdisc add dev eth0 root handle 1: prio bands 3
$K tc qdisc add dev eth0 parent 1:3 handle 30: netem delay 400ms 100ms distribution normal
$K tc filter add dev eth0 protocol ip parent 1:0 prio 3 u32 match ip dport 8001 0xffff flowid 1:3

# ... 90 s ... ESCALADA — fase 2: 2500 ms ± 500 ms
$K tc qdisc change dev eth0 parent 1:3 handle 30: netem delay 2500ms 500ms distribution normal

# ... 90 s ... ROLLBACK
$K tc qdisc del dev eth0 root
$K tc qdisc show dev eth0        # debe quedar solo noqueue/pfifo_fast
```

Si `sch_netem` no estuviera cargado: `ssh kubernet@192.168.0.21 'sudo modprobe sch_netem'`.

### E2 — Agotamiento de CPU (hipótesis H2)

El límite `cpu: "1"` que pusiste en la fase 3 es el que acota el radio de impacto: `stress-ng`
compite dentro del cgroup del pod y no puede robar CPU a los demás pods del nodo.

```bash
B=$(kubectl -n otel-lab get pod -l app=service-b -o name | head -1)
kubectl -n otel-lab exec $B -- stress-ng --cpu 4 --cpu-method matrixprod --timeout 120s --metrics-brief
```

El rollback es el propio `--timeout`. Evidencia del throttling:

```bash
kubectl -n otel-lab exec $B -- cat /sys/fs/cgroup/cpu.stat   # nr_throttled, throttled_usec
```

### E3 — Partición de red hacia PostgreSQL (hipótesis H3)

Aquí tu cluster permite algo que Compose no: reproducir el fallo **realista**, una NetworkPolicy
mal aplicada. Calico la impone con descarte silencioso —sin RST—, que es exactamente la condición
que convierte el manejo de error de service-b en código muerto.

```bash
cat > /tmp/deny-b-to-postgres.yaml <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-b-to-postgres
  namespace: otel-lab
spec:
  podSelector: { matchLabels: { app: service-b } }
  policyTypes: [Egress]
  egress:                                  # lista blanca que deja fuera a postgres
    - to: [{ podSelector: { matchLabels: { app: otel-collector } } }]
      ports: [{ protocol: TCP, port: 4317 }]
    - to: [{ namespaceSelector: {} }]      # DNS
      ports: [{ protocol: UDP, port: 53 }]
YAML

kubectl apply -f /tmp/deny-b-to-postgres.yaml      # INYECCIÓN
# ... 90 s ...
kubectl delete -f /tmp/deny-b-to-postgres.yaml     # ROLLBACK
```

Alternativa equivalente con iptables dentro del pod (más cercana a lo ejecutado en el informe):

```bash
kubectl -n otel-lab exec $B -- iptables -A OUTPUT -p tcp --dport 5432 -j DROP
kubectl -n otel-lab exec $B -- iptables -D OUTPUT -p tcp --dport 5432 -j DROP
```

### E4 (opcional, solo posible aquí) — Caída de nodo

Con tres nodos reales puedes probar lo que ningún entorno de un solo host permite:

```bash
kubectl drain kube-w1 --ignore-daemonsets --delete-emptydir-data   # INYECCIÓN
kubectl uncordon kube-w1                                            # ROLLBACK
```

Hipótesis natural: *"En estado estable, cuando se drene el nodo que aloja a service-b, esperamos
que Kubernetes lo reprograme en kube-w2 y que la indisponibilidad no supere los 30 s"*. Con una
sola réplica y sin PodDisruptionBudget, casi seguro se refuta.

---

## Fase 6 — Medir y analizar

```bash
python3 chaos/loadgen.py --url $TARGET --rps 40 --duration 420 \
        --out chaos/results/exp1_requests.csv
python3 chaos/analizar.py    exp1 chaos/results/exp1_requests.csv
python3 chaos/prom_extract.py exp1
python3 chaos/graficas.py
```

Antes de correrlos, en `analizar.py` y `prom_extract.py` la constante de Prometheus ya apunta a
`http://127.0.0.1:9090`, que es correcto si dejaste el port-forward abierto.

`analizar.py` y `prom_extract.py` leen las fases desde `results/<exp>_timeline.json`. Si inyectas
a mano en lugar de usar los scripts `exp*.py`, crea ese fichero con las marcas de tiempo:

```json
{"events":[{"ts":1788025784,"event":"INICIO"},{"ts":1788025904,"event":"FASE_1"},
           {"ts":1788025994,"event":"FASE_2"},{"ts":1788026084,"event":"RECUPERACION"},
           {"ts":1788026204,"event":"FIN"}], "canary":[]}
```

(`date +%s` en el momento de cada transición.)

---

## Reglas que no se saltan

1. Nunca sin plan de Game Day y rollback definido. Este runbook **es** el plan.
2. Cada inyección lleva dos formas de revertirse: la manual de arriba y una segunda automática
   (el `--timeout` de stress-ng, el `TOTAL_CHAOS_DURATION` de Litmus, o el watchdog de los
   scripts `exp*.py`). Si te desconectas del cluster a mitad de experimento, el fallo debe
   retirarse solo.
3. Toma una instantánea de VirtualBox de los tres nodos antes de la primera sesión. Es el
   rollback de último recurso.
4. La hipótesis se escribe **antes** de inyectar. Un experimento sin predicción previa no
   enseña nada.

## Equivalencia con LitmusChaos

La actividad cita Litmus y Chaos Monkey. Lo de arriba es exactamente lo que hace Litmus por
debajo, sin la capa de operador. Si quieres además la versión declarativa:

```bash
helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
helm install chaos litmuschaos/litmus -n litmus --create-namespace
kubectl apply -n otel-lab -f https://hub.litmuschaos.io/api/chaos/3.10.0?file=charts/generic/experiments.yaml
```

Correspondencia con las tres hipótesis:

| Hipótesis | Experimento de Litmus | Parámetros clave |
|---|---|---|
| H1 | `pod-network-latency` | `NETWORK_LATENCY=400`, `TOTAL_CHAOS_DURATION=90`, `TARGET_CONTAINER=service-a` |
| H2 | `pod-cpu-hog` | `CPU_CORES=1`, `TOTAL_CHAOS_DURATION=120` |
| H3 | `pod-network-loss` sobre el pod de postgres | `NETWORK_PACKET_LOSS_PERCENTAGE=100` |

Comprueba antes que las imágenes de `litmuschaos/go-runner` tengan variante arm64 para la versión
que instales; si no, quédate con la ruta manual de la fase 5, que no depende de imágenes externas.
