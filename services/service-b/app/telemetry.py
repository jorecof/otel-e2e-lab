"""
Configuración centralizada de OpenTelemetry para service-b.

Emite los 3 pilares de observabilidad:
  - Trazas  : OTLP gRPC -> OTel Collector -> Jaeger / Tempo / X-Ray
  - Métricas: OTLP gRPC -> OTel Collector -> Prometheus
  - Logs    : JSON estructurado (stdout) + OTLP -> Collector -> Loki/CloudWatch
              Cada línea incluye trace_id / span_id para correlación cross-signal.

La propagación de contexto usa W3C TraceContext (default del SDK de Python).
Se puede desactivar por completo con OTEL_ENABLED=false (línea base del benchmark).
"""
import json
import logging
import os
import sys
from datetime import datetime, timezone

OTEL_ENABLED = os.getenv("OTEL_ENABLED", "true").lower() == "true"
SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "service-b")
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "1.0.0")
ENVIRONMENT = os.getenv("DEPLOY_ENV", "local")
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")


class JsonLogFormatter(logging.Formatter):
    """Logs estructurados en JSON con trace_id/span_id inyectados por OTel."""

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "severity": record.levelname,
            "service": SERVICE_NAME,
            "message": record.getMessage(),
            "logger": record.name,
            # Inyectados por LoggingInstrumentor (vacíos si no hay span activo)
            "trace_id": getattr(record, "otelTraceID", ""),
            "span_id": getattr(record, "otelSpanID", ""),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        for attr in ("http_method", "http_route", "item_id", "duration_ms"):
            if hasattr(record, attr):
                payload[attr] = getattr(record, attr)
        return json.dumps(payload, ensure_ascii=False)


def _configure_json_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonLogFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(logging.INFO)


def setup_telemetry(app=None, engine=None):
    """Inicializa trazas, métricas y logs. Devuelve (tracer, meter) o (None, None)."""
    _configure_json_logging()

    if not OTEL_ENABLED:
        logging.getLogger(__name__).info("OpenTelemetry DESACTIVADO (baseline)")
        return None, None

    from opentelemetry import metrics, trace
    from opentelemetry._logs import set_logger_provider
    from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
    from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.logging import LoggingInstrumentor
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    resource = Resource.create(
        {
            "service.name": SERVICE_NAME,
            "service.version": SERVICE_VERSION,
            "deployment.environment": ENVIRONMENT,
        }
    )

    # ---- Trazas ----
    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True))
    )
    trace.set_tracer_provider(tracer_provider)

    # ---- Métricas ----
    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=OTLP_ENDPOINT, insecure=True),
        export_interval_millis=10_000,
    )
    meter_provider = MeterProvider(resource=resource, metric_readers=[reader])
    metrics.set_meter_provider(meter_provider)

    # ---- Logs (OTLP hacia el Collector, además del stdout JSON) ----
    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter(endpoint=OTLP_ENDPOINT, insecure=True))
    )
    set_logger_provider(logger_provider)
    logging.getLogger().addHandler(
        LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
    )

    # Inyecta otelTraceID / otelSpanID en cada LogRecord
    LoggingInstrumentor().instrument(set_logging_format=False)

    # ---- Auto-instrumentación HTTP + DB ----
    if app is not None:
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

        FastAPIInstrumentor.instrument_app(app, tracer_provider=tracer_provider)
    if engine is not None:
        from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

        SQLAlchemyInstrumentor().instrument(engine=engine, tracer_provider=tracer_provider)

    tracer = trace.get_tracer(SERVICE_NAME, SERVICE_VERSION)
    meter = metrics.get_meter(SERVICE_NAME, SERVICE_VERSION)
    logging.getLogger(__name__).info("OpenTelemetry inicializado", extra={})
    return tracer, meter
