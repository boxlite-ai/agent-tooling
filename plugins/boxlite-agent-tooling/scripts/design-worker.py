#!/usr/bin/env python3
"""Bound task input, output streams, and collection time for a supervised worker."""
import json
import subprocess
import threading
import time


def collect(child, task, deadline, owner, phase=None, maximum_deadline=None):
    output, errors = bytearray(), bytearray()
    failed = threading.Event()

    def drain(stream, target):
        while True:
            block = stream.read(4096)
            if not block:
                return
            if len(target) + len(block) > 1048576:
                failed.set()
                child.kill()
                return
            target.extend(block)

    def send():
        try:
            child.stdin.write(task)
            child.stdin.close()
        except (BrokenPipeError, OSError):
            failed.set()

    threads = [threading.Thread(target=drain, args=pair, daemon=True)
               for pair in ((child.stdout, output), (child.stderr, errors))]
    threads.append(threading.Thread(target=send, daemon=True))
    for thread in threads:
        thread.start()
    phase_seen = False
    while child.poll() is None:
        if not owner.parent_alive():
            raise InterruptedError("host lifetime ended")
        if phase is not None and not phase_seen and phase.exists():
            if phase.stat().st_size > 512:
                raise ValueError("invalid worker phase record")
            record = json.loads(phase.read_bytes())
            hard_stop = record.get("hard_stop")
            if type(hard_stop) not in (int, float) or not time.monotonic() <= hard_stop <= maximum_deadline:
                raise ValueError("invalid worker phase deadline")
            deadline, phase_seen = hard_stop, True
        if time.monotonic() >= deadline:
            raise ValueError("worker collection deadline exceeded" if phase_seen or phase is None else "worker setup exceeded 30 seconds")
        try:
            child.wait(timeout=min(0.1, max(0.01, deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            pass
    owner.close()
    for thread in threads:
        thread.join(timeout=0.5)
    if failed.is_set() or any(thread.is_alive() for thread in threads):
        raise ValueError("worker output or input channel failed")
    child.stdout.close()
    child.stderr.close()
    return bytes(output), bytes(errors)
