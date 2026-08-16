// Generador de tráfico para capturar evidencias en la nube (GCP y AWS).
//
// A diferencia de load-test.js (75 VUs, benchmark de overhead), este script
// mantiene carga moderada y sostenida el tiempo que necesites para tomar las
// capturas, e incluye un porcentaje de peticiones fallidas a propósito para que
// el panel de errores y las trazas de caso negativo tengan datos.
//
// Uso:
//   GCP (con port-forward activo en 8080):
//     k6 run benchmark/cloud-traffic.js
//   AWS (IP pública de la task):
//     TARGET_URL=http://IP_SERVICE_A:8000 k6 run benchmark/cloud-traffic.js
//   Ajustes:
//     DURATION=15m VUS=20 k6 run benchmark/cloud-traffic.js
import http from "k6/http";
import { check, sleep } from "k6";

const BASE = __ENV.TARGET_URL || "http://localhost:8080";
const DURATION = __ENV.DURATION || "10m";
const VUS = parseInt(__ENV.VUS || "8", 10);

// El 404 es intencional: sin esto k6 lo contaría como fallo y el resumen
// mostraría ~10 % de error, lo que confundiría al leer el reporte.
http.setResponseCallback(http.expectedStatuses(200, 404));

export const options = {
  scenarios: {
    evidencia: {
      executor: "constant-vus",
      vus: VUS,
      duration: DURATION,
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(99)<2000"],
  },
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
};

export default function () {
  const itemId = Math.floor(Math.random() * 5) + 1;
  const qty = Math.floor(Math.random() * 9) + 1;

  const res = http.get(`${BASE}/api/orders/${itemId}?qty=${qty}`, {
    tags: { caso: "orden_ok" },
  });
  check(res, {
    "orden creada (200)": (r) => r.status === 200,
    "trae total calculado": (r) => r.status === 200 && r.json("total") > 0,
  });

  // 1 de cada 10 iteraciones: item inexistente. Genera un 404 que puebla el
  // panel de errores y deja una traza de caso negativo en Jaeger / X-Ray.
  if (Math.random() < 0.1) {
    const nf = http.get(`${BASE}/api/orders/999`, { tags: { caso: "no_encontrado" } });
    check(nf, { "404 esperado": (r) => r.status === 404 });
  }

  sleep(Math.random() * 0.4 + 0.2); // think time 200-600 ms
}
