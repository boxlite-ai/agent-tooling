#!/usr/bin/env python3
"""Owned worker/broker lifetimes, independent of native MCP process-group behavior."""
import ctypes
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import threading
import time


class WindowsJob:
    """Assign a suspended child before its first instruction; close kills descendants."""
    def __init__(self):
        from ctypes import wintypes as w
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)

        class Basic(ctypes.Structure):
            _fields_ = [("process_time", ctypes.c_longlong), ("job_time", ctypes.c_longlong),
                        ("flags", w.DWORD), ("min_working", ctypes.c_size_t), ("max_working", ctypes.c_size_t),
                        ("process_limit", w.DWORD), ("affinity", ctypes.c_size_t),
                        ("priority", w.DWORD), ("scheduling", w.DWORD)]

        class IO(ctypes.Structure):
            _fields_ = [(name, ctypes.c_ulonglong) for name in
                        ("read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes")]

        class Limits(ctypes.Structure):
            _fields_ = [("basic", Basic), ("io", IO), ("process_memory", ctypes.c_size_t),
                        ("job_memory", ctypes.c_size_t), ("peak_process", ctypes.c_size_t),
                        ("peak_job", ctypes.c_size_t)]

        self.kernel.CreateJobObjectW.restype = w.HANDLE
        self.kernel.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
        self.kernel.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        self.kernel.CloseHandle.argtypes = [w.HANDLE]
        self.kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
        self.kernel.OpenProcess.restype = w.HANDLE
        self.kernel.IsProcessInJob.argtypes = [w.HANDLE, w.HANDLE, ctypes.POINTER(w.BOOL)]
        self.kernel.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
        self.kernel.WaitForSingleObject.restype = w.DWORD
        self.close_guard = threading.Lock()
        self.handle = self.kernel.CreateJobObjectW(None, None)
        limits = Limits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; no breakaway.
        if not self.handle or not self.kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            raise OSError("cannot create kill-on-close job")

    def assign_resume(self, child):
        from ctypes import wintypes as w
        if not self.kernel.AssignProcessToJobObject(self.handle, int(child._handle)):
            child.kill()
            raise OSError("cannot assign suspended worker to job")

        class ThreadEntry(ctypes.Structure):
            _fields_ = [(name, w.DWORD) for name in ("size", "usage", "id", "owner", "priority", "delta", "flags")]

        self.kernel.CreateToolhelp32Snapshot.restype = w.HANDLE
        self.kernel.OpenThread.restype = w.HANDLE
        self.kernel.Thread32First.argtypes = [w.HANDLE, ctypes.POINTER(ThreadEntry)]
        self.kernel.Thread32Next.argtypes = [w.HANDLE, ctypes.POINTER(ThreadEntry)]
        self.kernel.ResumeThread.argtypes = [w.HANDLE]
        self.kernel.ResumeThread.restype = w.DWORD
        threads = self.kernel.CreateToolhelp32Snapshot(4, 0)
        entry = ThreadEntry()
        entry.size = ctypes.sizeof(entry)
        found = False
        try:
            present = self.kernel.Thread32First(threads, ctypes.byref(entry))
            while present:
                if entry.owner == child.pid:
                    thread = self.kernel.OpenThread(2, False, entry.id)
                    try:
                        if not thread or self.kernel.ResumeThread(thread) == 0xffffffff:
                            raise OSError("cannot resume assigned worker")
                        found = True
                    finally:
                        if thread:
                            self.kernel.CloseHandle(thread)
                present = self.kernel.Thread32Next(threads, ctypes.byref(entry))
        finally:
            self.kernel.CloseHandle(threads)
        if not found:
            raise OSError("suspended worker thread unavailable")

    def close(self):
        with self.close_guard:
            if self.handle:
                self.kernel.CloseHandle(self.handle)
                self.handle = None

    def member_handle(self, pid):
        from ctypes import wintypes as w
        handle = self.kernel.OpenProcess(0x101101, False, pid)
        inside = w.BOOL()
        if not handle or not self.kernel.IsProcessInJob(handle, self.handle, ctypes.byref(inside)) or not inside.value:
            if handle:
                self.kernel.CloseHandle(handle)
            raise OSError("broker is outside the assigned worker job")
        return handle


class Owner:
    def __init__(self, directory, nonce, python, bash, group_script):
        self.directory, self.nonce = directory, nonce
        self.python, self.bash, self.group_script = python, bash, group_script
        self.channels = []
        self.groups = []
        self.broker_jobs = []
        self.children = []
        self.parent_pid = os.getppid()
        self.closed = False
        self.broker_registered = threading.Event()
        self.guard = threading.Lock()
        self.job = WindowsJob() if os.name == "nt" else None
        self.parent_handle = self.job.kernel.OpenProcess(0x100000, False, self.parent_pid) if self.job else None
        if self.job and not self.parent_handle:
            self.job.close()
            raise OSError("supervisor parent cannot be inspected")
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(2)
        self.server.settimeout(0.2)
        self.address = self.server.getsockname()
        self.listener = threading.Thread(target=self._register, daemon=True)
        self.listener.start()

    def _register(self):
        while not self.closed:
            try:
                channel, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            channel.settimeout(2)
            try:
                with channel.makefile("rb") as incoming:
                    packet = incoming.readline(1025)
                record = json.loads(packet)
                if (len(packet) > 1024 or not packet.endswith(b"\n") or set(record) != {"nonce", "pid"}
                        or record.get("nonce") != self.nonce
                        or any(isinstance(item, socket.socket) for item in self.channels) or self.closed
                        or type(record.get("pid")) is not int or not 2 <= record["pid"] <= 4294967295):
                    raise ValueError("invalid broker registration")
                if not self.job and os.getpgid(record["pid"]) != record["pid"]:
                    raise ValueError("broker must own its group")
                with self.guard:
                    if self.closed:
                        raise ValueError("supervisor closed")
                    self.channels.append(channel)
                    if not self.job:
                        self.groups.append(record["pid"])
                    else:
                        handle = self.job.member_handle(record["pid"])
                        try:
                            broker_job = WindowsJob()
                        except OSError:
                            self.job.kernel.CloseHandle(handle)
                            raise
                        if not broker_job.kernel.AssignProcessToJobObject(broker_job.handle, handle):
                            broker_job.close()
                            self.job.kernel.CloseHandle(handle)
                            raise OSError("cannot assign broker to its nested lifetime job")
                        monitor = threading.Thread(target=self._watch_broker, args=(handle, broker_job), daemon=True)
                        self.broker_jobs.append((broker_job, monitor))
                        monitor.start()
                    channel.sendall(b"ready\n")
                    self.broker_registered.set()
                channel.settimeout(None)
            except (ValueError, OSError):
                channel.close()

    def _watch_broker(self, handle, job):
        try:
            while not self.closed and self.job.kernel.WaitForSingleObject(handle, 50) == 258:
                pass
        finally:
            job.close()
            self.job.kernel.CloseHandle(handle)

    def launch(self, command, environment):
        if self.job:
            child = subprocess.Popen(command, cwd=self.directory, env=environment,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                creationflags=0x4)  # CREATE_SUSPENDED
            self.children.append(child)
            self.job.assign_resume(child)
            return child
        reader, writer = os.pipe()
        group = self.directory / "worker-group"
        group.mkdir()
        command = [self.python, "-I", str(Path(__file__).resolve()), "leader", str(reader),
                   self.bash, str(self.group_script), str(group), *command]
        try:
            child = subprocess.Popen(command, cwd=self.directory, env=environment,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                pass_fds=(reader,), start_new_session=True)
        finally:
            os.close(reader)
        self.channels.append(writer)
        self.groups.append(child.pid)
        self.children.append(child)
        return child

    def parent_alive(self):
        if self.job:
            return self.job.kernel.WaitForSingleObject(self.parent_handle, 0) == 258
        return self.parent_pid > 1 and os.getppid() == self.parent_pid

    def broker_command(self, broker, payload):
        return [self.python, "-I", str(Path(__file__).resolve()), "broker",
                str(self.address[1]), self.nonce, self.bash, str(self.group_script),
                str(self.directory / "broker-group"), self.python, "-I", str(broker), str(payload)]

    def close(self):
        with self.guard:
            if self.closed:
                return
            self.closed = True
        self.server.close()
        self.listener.join(timeout=1)
        for channel in self.channels:
            if isinstance(channel, int):
                os.close(channel)
            else:
                try:
                    channel.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                channel.close()
        if self.job:
            for job, monitor in self.broker_jobs:
                job.close()
                monitor.join(timeout=1)
            self.job.close()
            self.job.kernel.CloseHandle(self.parent_handle)
            for child in self.children:
                child.wait(timeout=2)
            return
        until = time.monotonic() + 4
        controllers = [self.directory / name / "group-kill" for name in ("worker-group", "broker-group")
                       if (self.directory / name).exists()]
        while time.monotonic() < until:
            if all(path.exists() for path in controllers):
                break
            time.sleep(0.02)
        for group in self.groups:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for child in self.children:
            child.wait(timeout=2)


def bootstrap():
    mode = sys.argv[1]
    if mode == "leader":
        descriptor = int(sys.argv[2])
        os.dup2(descriptor, 3, inheritable=True)
        if descriptor != 3:
            os.close(descriptor)
        os.execv(sys.argv[3], sys.argv[3:])
    if mode == "broker":
        if os.name != "nt" and os.getpgrp() != os.getpid():
            os.setsid()
        channel = socket.create_connection(("127.0.0.1", int(sys.argv[2])), timeout=3)
        channel.sendall(json.dumps({"nonce": sys.argv[3], "pid": os.getpid()}).encode() + b"\n")
        if channel.recv(64) != b"ready\n":
            raise ValueError("supervisor unavailable")
        channel.settimeout(None)
        if os.name == "nt":
            from ctypes import wintypes as w
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.GetCurrentProcess.restype = w.HANDLE
            kernel.IsProcessInJob.argtypes = [w.HANDLE, w.HANDLE, ctypes.POINTER(w.BOOL)]
            inside = w.BOOL()
            if not kernel.IsProcessInJob(kernel.GetCurrentProcess(), None, ctypes.byref(inside)) or not inside.value:
                raise ValueError("broker outside supervisor job")
            sys.exit(subprocess.call(sys.argv[7:]))
        group = Path(sys.argv[6])
        group.mkdir()
        os.dup2(channel.fileno(), 3, inheritable=True)
        os.set_inheritable(3, True)
        os.execv(sys.argv[4], sys.argv[4:])


if __name__ == "__main__":
    bootstrap()
