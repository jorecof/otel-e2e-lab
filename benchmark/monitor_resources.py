#!/usr/bin/env python3
"""Muestrea CPU% y RSS (MB) de los procesos uvicorn (service-a + service-b)
cada 2 s durante el benchmark y escribe un CSV con el agregado."""
import csv
import sys
import time

import psutil

OUT = sys.argv[1] if len(sys.argv) > 1 else "resources.csv"
DURATION = int(sys.argv[2]) if len(sys.argv) > 2 else 300


def find_procs():
    """Procesos master de uvicorn + todos sus workers (hijos recursivos)."""
    procs = {}
    for p in psutil.process_iter(["cmdline"]):
        try:
            cmd = " ".join(p.info["cmdline"] or [])
            if "uvicorn" in cmd and "app.main:app" in cmd:
                procs[p.pid] = p
                for c in p.children(recursive=True):
                    procs[c.pid] = c
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return list(procs.values())


def main():
    procs = find_procs()
    print(f"Monitoreando {len(procs)} procesos uvicorn -> {OUT}")
    for p in procs:
        p.cpu_percent(None)  # primer llamado: inicializa el contador

    t_end = time.time() + DURATION
    with open(OUT, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ts", "n_procs", "cpu_percent_total", "rss_mb_total"])
        while time.time() < t_end:
            time.sleep(2)
            cpu = rss = 0.0
            alive = 0
            for p in procs:
                try:
                    cpu += p.cpu_percent(None)
                    rss += p.memory_info().rss / (1024 * 1024)
                    alive += 1
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
            w.writerow([round(time.time(), 1), alive, round(cpu, 1), round(rss, 1)])
            f.flush()


if __name__ == "__main__":
    main()
