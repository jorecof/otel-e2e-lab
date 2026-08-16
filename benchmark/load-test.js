// Benchmark de overhead OTel — k6
// Carga realista: ramp a 75 VUs concurrentes, 5 minutos en total.
// Se ejecuta 2 veces: OTEL_ENABLED=false (línea base) y OTEL_ENABLED=true.
import http from "k6/http";
import { check, sleep } from "k6";

const BASE = __ENV.TARGET_URL || "http://localhost:8000";

export const options = {
  stages: [
    { duration: "30s", target: 75 },  // ramp-up
    { duration: "4m", target: 75 },   // carga sostenida (50-100 usuarios)
    { duration: "30s", target: 0 },   // ramp-down
  ],
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(99)<1000"],
  },
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
};

export default function () {
  const itemId = Math.floor(Math.random() * 5) + 1;
  const qty = Math.floor(Math.random() * 10) + 1;
  const res = http.get(`${BASE}/api/orders/${itemId}?qty=${qty}`);
  check(res, { "status 200": (r) => r.status === 200 });
  sleep(Math.random() * 0.3 + 0.1); // think time 100-400ms
}
