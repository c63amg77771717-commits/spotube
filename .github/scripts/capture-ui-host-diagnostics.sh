#!/bin/bash
# Best-effort, bounded diagnostics. No process arguments or environment are recorded.
exec python3 - "$@" <<'PY'
import datetime
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

if len(sys.argv) != 2 or not os.environ.get('RUNNER_TEMP'):
    raise SystemExit('A diagnostic directory inside RUNNER_TEMP is required')
directory = Path(sys.argv[1]).resolve()
if Path(os.environ['RUNNER_TEMP']).resolve() not in directory.parents:
    raise SystemExit('The diagnostic directory must be inside RUNNER_TEMP')
directory.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
deadline = started + 900

def stop(_signum, _frame):
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

def capture(command):
    remaining = deadline - time.monotonic()
    if remaining <= 1:
        return 'diagnostic deadline reached\n'
    try:
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, errors='replace', start_new_session=True)
    except OSError as error:
        return f'diagnostic unavailable: {type(error).__name__}\n'
    try:
        return child.communicate(timeout=min(5, remaining - 1))[0]
    except subprocess.TimeoutExpired:
        return 'diagnostic command timed out\n'
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass

names = {'LovelyMusic', 'LovelyMusicUITests-Runner', 'Simulator',
         'CoreSimulatorService', 'com.apple.CoreSimulator.CoreSimulatorService'}
with (directory / 'host-process-metrics.log').open('a', buffering=1) as metrics:
    for tick in range(30):
        time.sleep(max(0, min(started + tick * 30, deadline) - time.monotonic()))
        if time.monotonic() >= deadline:
            break
        stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        metrics.write(f'\nUTC {stamp}; elapsed_seconds={time.monotonic() - started:.1f}\n')
        metrics.write(f'loadavg_1m_5m_15m={os.getloadavg()}\n')
        metrics.write('memory_total_bytes: ' + capture(['/usr/sbin/sysctl', '-n', 'hw.memsize']))
        metrics.write(capture(['/usr/bin/vm_stat']))
        snapshot = capture(['/bin/ps', '-A', '-o', 'pid=,pcpu=,pmem=,etime=,comm='])
        metrics.write('PID CPU% PMEM% ELAPSED COMM\n')
        app_pids = []
        for line in snapshot.splitlines():
            fields = line.split(None, 4)
            if len(fields) != 5 or Path(fields[4]).name not in names:
                continue
            metrics.write(line + '\n')
            if Path(fields[4]).name == 'LovelyMusic' and fields[0].isdigit():
                app_pids.append(int(fields[0]))
        if app_pids:
            # At most one one-second app sample per tick; prefer the newest app process.
            pid = max(app_pids)
            sample_file = directory / f'sample-{tick:02d}-pid-{pid}.txt'
            output = capture(['/usr/bin/sample', str(pid), '1', '-file', str(sample_file)])
            with (directory / 'sample-status.log').open('a') as status:
                status.write(f'UTC {stamp}; pid={pid}\n{output}\n')
PY
