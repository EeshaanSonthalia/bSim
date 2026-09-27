#!/usr/bin/env python3
"""Guard development tools with fresh M4 sensor readings and process-group stops."""
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

root = Path(__file__).resolve().parent.parent
sensor = root / ".cache/thermal-monitor"
if not sensor.is_file():
    raise SystemExit("Run scripts/bootstrap.sh first")
if len(sys.argv) < 2:
    raise SystemExit("usage: thermal-run.py command [args]")
monitor = subprocess.Popen([str(sensor), "--watch"], stdout=subprocess.PIPE, text=True)
selector = selectors.DefaultSelector()
selector.register(monitor.stdout, selectors.EVENT_READ)
child = None
paused = True
peak = [0.0, 0.0, 0.0]

def stop(signum, frame):
    raise KeyboardInterrupt

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
result = 1
try:
    while child is None or child.poll() is None:
        if not selector.select(timeout=1.0):
            raise RuntimeError("Thermal sensor feed expired")
        line = monitor.stdout.readline()
        if not line:
            raise RuntimeError("Thermal sensor feed stopped")
        t = json.loads(line)
        values = [t["batteryC"], t["cpuC"], t["gpuC"]]
        now = time.clock_gettime(time.CLOCK_MONOTONIC)
        if not all(0 < v < 130 for v in values) or abs(now - t["sampleTime"]) > 1:
            raise RuntimeError("Invalid thermal sample")
        peak = [max(a, b) for a, b in zip(peak, values)]
        hot = values[0] >= 37.5 or max(values[1:]) >= 75 or t["thermalState"] >= 1
        cool = values[0] <= 36 and max(values[1:]) <= 65 and t["thermalState"] == 0
        if child is None and cool:
            child = subprocess.Popen(sys.argv[1:], start_new_session=True)
            paused = False
        elif child is not None and hot and not paused:
            os.killpg(child.pid, signal.SIGSTOP)
            paused = True
            print("bSim thermal guard: cooling", values, file=sys.stderr)
        elif child is not None and cool and paused:
            os.killpg(child.pid, signal.SIGCONT)
            paused = False
    result = child.returncode
except KeyboardInterrupt:
    result = 130
except (OSError, RuntimeError, ValueError, KeyError) as error:
    print(f"bSim thermal guard: {error}", file=sys.stderr)
finally:
    if child is not None and child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
        os.killpg(child.pid, signal.SIGCONT)
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
    monitor.terminate()
    monitor.wait()
    selector.close()
    print(f"bSim thermal peaks: battery {peak[0]:.1f} C, CPU {peak[1]:.1f} C, GPU {peak[2]:.1f} C", file=sys.stderr)
sys.exit(result)
