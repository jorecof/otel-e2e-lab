"""
service-b: servicio de inventario (FastAPI + PostgreSQL).

Pilares emitidos:
  - Trazas : auto-instrumentación FastAPI + SQLAlchemy, custom span
             "inventory.check_stock" para lógica de negocio crítica.
  - Métricas: counter de consultas de stock + histograma de latencia de negocio.
  - Logs   : JSON estructurado con trace_id/span_id.
"""
import logging
import os
import random
import time

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sqlalchemy import Column, Integer, Numeric, String, create_engine, select
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session, declarative_base

DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql+psycopg2://otel:otel@postgres:5432/inventory"
)
engine = create_engine(DATABASE_URL, pool_size=20, max_overflow=40, pool_pre_ping=True)
Base = declarative_base()
logger = logging.getLogger("service-b")

app = FastAPI(title="service-b (inventory)")

from .telemetry import setup_telemetry  # noqa: E402

tracer, meter = setup_telemetry(app=app, engine=engine)

if meter:
    stock_checks = meter.create_counter(
        "inventory_stock_checks_total",
        description="Total de verificaciones de stock",
    )
    stock_latency = meter.create_histogram(
        "inventory_check_duration_ms",
        unit="ms",
        description="Duración de la lógica de verificación de stock",
    )
else:
    stock_checks = stock_latency = None


class Item(Base):
    __tablename__ = "items"
    id = Column(Integer, primary_key=True)
    sku = Column(String(32), unique=True, nullable=False)
    name = Column(String(128), nullable=False)
    stock = Column(Integer, nullable=False, default=0)
    price = Column(Numeric(10, 2), nullable=False)


class ItemOut(BaseModel):
    id: int
    sku: str
    name: str
    stock: int
    price: float
    in_stock: bool


SEED = [
    ("SKU-001", "Teclado mecánico", 120, 89.99),
    ("SKU-002", "Mouse inalámbrico", 300, 25.50),
    ("SKU-003", "Monitor 27''", 45, 310.00),
    ("SKU-004", "Dock USB-C", 80, 129.00),
    ("SKU-005", "Webcam 4K", 12, 199.99),
]


@app.on_event("startup")
def seed_db() -> None:
    Base.metadata.create_all(engine)
    with Session(engine) as s:
        if not s.execute(select(Item.id).limit(1)).first():
            for sku, name, stock, price in SEED:
                s.add(Item(sku=sku, name=name, stock=stock, price=price))
            s.commit()
            logger.info("Base de datos inicializada con %d items", len(SEED))


def _check_stock_logic(item: Item) -> bool:
    """Lógica de negocio crítica: instrumentada con custom span."""
    start = time.perf_counter()

    def _run() -> bool:
        # Simula validación de reservas/reglas de negocio
        time.sleep(random.uniform(0.002, 0.008))
        return item.stock > 0

    if tracer:
        with tracer.start_as_current_span("inventory.check_stock") as span:
            span.set_attribute("app.item.sku", item.sku)
            span.set_attribute("app.item.stock", item.stock)
            result = _run()
            span.set_attribute("app.item.in_stock", result)
    else:
        result = _run()

    elapsed_ms = (time.perf_counter() - start) * 1000
    if stock_checks:
        stock_checks.add(1, {"sku": item.sku, "in_stock": str(result)})
        stock_latency.record(elapsed_ms, {"sku": item.sku})
    return result


@app.get("/health")
def health():
    return {"status": "ok", "service": "service-b"}


@app.get("/items/{item_id}", response_model=ItemOut)
def get_item(item_id: int):
    # Igual que en service-a: una excepción no manejada haría que Starlette
    # genere el 500 fuera del alcance del middleware de OTel, y la métrica se
    # registraría sin http_status_code. Capturándola, el 503 sí queda etiquetado
    # y el panel de errores refleja la caída de la base de datos.
    try:
        session = Session(engine)
    except OperationalError as exc:
        logger.error("Base de datos inalcanzable: %s", exc)
        raise HTTPException(status_code=503, detail="database unavailable") from exc

    with session as s:
        try:
            item = s.get(Item, item_id)  # SELECT auto-instrumentado por SQLAlchemy
        except OperationalError as exc:
            logger.error("Fallo al consultar la base de datos: %s", exc,
                         extra={"item_id": item_id})
            raise HTTPException(status_code=503, detail="database unavailable") from exc
        if item is None:
            logger.warning("Item no encontrado", extra={"item_id": item_id})
            raise HTTPException(status_code=404, detail="item not found")
        in_stock = _check_stock_logic(item)
        logger.info(
            "Stock verificado para %s", item.sku, extra={"item_id": item_id}
        )
        return ItemOut(
            id=item.id,
            sku=item.sku,
            name=item.name,
            stock=item.stock,
            price=float(item.price),
            in_stock=in_stock,
        )


@app.get("/items", response_model=list[ItemOut])
def list_items():
    with Session(engine) as s:
        items = s.execute(select(Item)).scalars().all()
        return [
            ItemOut(
                id=i.id, sku=i.sku, name=i.name, stock=i.stock,
                price=float(i.price), in_stock=i.stock > 0,
            )
            for i in items
        ]
