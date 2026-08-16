"""
service-a: servicio de órdenes (FastAPI). Depende de service-b vía HTTP.

Pilares emitidos:
  - Trazas : auto-instrumentación FastAPI + HTTPX (propagación W3C TraceContext
             hacia service-b), custom span "orders.calculate_total".
  - Métricas: counter de órdenes procesadas + histograma del valor de la orden.
  - Logs   : JSON estructurado con trace_id/span_id.
"""
import logging
import os
import random
import time

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

SERVICE_B_URL = os.getenv("SERVICE_B_URL", "http://service-b:8001")
logger = logging.getLogger("service-a")

app = FastAPI(title="service-a (orders)")

from .telemetry import OTEL_ENABLED, setup_telemetry  # noqa: E402

tracer, meter = setup_telemetry(app=app)

if OTEL_ENABLED:
    # Auto-instrumentación del cliente HTTP: inyecta el header W3C `traceparent`
    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

    HTTPXClientInstrumentor().instrument()

if meter:
    orders_counter = meter.create_counter(
        "orders_processed_total", description="Órdenes procesadas"
    )
    order_value = meter.create_histogram(
        "order_total_value", unit="USD", description="Valor total de la orden"
    )
else:
    orders_counter = order_value = None

client = httpx.Client(base_url=SERVICE_B_URL, timeout=10.0)

TAX_RATE = 0.19
DISCOUNT_THRESHOLD = 500.0


class OrderOut(BaseModel):
    order_id: str
    item_id: int
    sku: str
    quantity: int
    unit_price: float
    subtotal: float
    discount: float
    tax: float
    total: float
    in_stock: bool


def _calculate_total(unit_price: float, quantity: int) -> dict:
    """Lógica de negocio crítica: instrumentada con custom span."""

    def _run() -> dict:
        subtotal = round(unit_price * quantity, 2)
        discount = round(subtotal * 0.05, 2) if subtotal > DISCOUNT_THRESHOLD else 0.0
        tax = round((subtotal - discount) * TAX_RATE, 2)
        # Simula reglas de pricing adicionales
        time.sleep(random.uniform(0.001, 0.004))
        return {
            "subtotal": subtotal,
            "discount": discount,
            "tax": tax,
            "total": round(subtotal - discount + tax, 2),
        }

    if tracer:
        with tracer.start_as_current_span("orders.calculate_total") as span:
            result = _run()
            span.set_attribute("app.order.subtotal", result["subtotal"])
            span.set_attribute("app.order.discount_applied", result["discount"] > 0)
            span.set_attribute("app.order.total", result["total"])
            return result
    return _run()


@app.get("/health")
def health():
    return {"status": "ok", "service": "service-a"}


@app.get("/api/orders/{item_id}", response_model=OrderOut)
def create_order(item_id: int, qty: int = 1):
    """Crea una orden: consulta stock/precio en service-b y calcula el total."""
    if qty < 1 or qty > 100:
        logger.warning("Cantidad inválida", extra={"item_id": item_id})
        raise HTTPException(status_code=400, detail="qty must be between 1 and 100")

    # Llamada HTTP auto-instrumentada: el trace_id se propaga a service-b
    resp = client.get(f"/items/{item_id}")
    if resp.status_code == 404:
        logger.warning("Item inexistente en inventario", extra={"item_id": item_id})
        raise HTTPException(status_code=404, detail="item not found in inventory")
    resp.raise_for_status()
    item = resp.json()

    pricing = _calculate_total(item["price"], qty)
    order_id = f"ORD-{random.randint(100000, 999999)}"

    if orders_counter:
        orders_counter.add(1, {"sku": item["sku"], "in_stock": str(item["in_stock"])})
        order_value.record(pricing["total"], {"sku": item["sku"]})

    logger.info(
        "Orden %s procesada: %s x%d total=%.2f",
        order_id, item["sku"], qty, pricing["total"],
        extra={"item_id": item_id},
    )
    return OrderOut(
        order_id=order_id,
        item_id=item["id"],
        sku=item["sku"],
        quantity=qty,
        unit_price=item["price"],
        in_stock=item["in_stock"],
        **pricing,
    )
