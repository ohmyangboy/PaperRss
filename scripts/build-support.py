#!/usr/bin/env python3
"""串行执行构建，回收本次测试临时目录，并只轮转本工具创建的报告。"""

import argparse
import contextlib
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def prune_reports(directory, days):
    cutoff = time.time() - days * 86400
    for path in directory.glob("run-*.log"):
        if not path.is_symlink() and path.is_file() and path.stat().st_mtime < cutoff:
            path.unlink()


def run(command, temporary=False, unlocked=False):
    state = ROOT / "build"
    reports = ROOT / ".scratch" / "reports"
    state.mkdir(exist_ok=True)
    reports.mkdir(parents=True, exist_ok=True)
    # 不删除锁文件：所有等待者必须始终锁定同一个 inode。
    with (state / ".pipeline.lock").open("a") as lock:
        print("等待 PaperRss 构建锁…", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        prune_reports(reports, 30)
        if unlocked:
            fcntl.flock(lock, fcntl.LOCK_UN)
        with contextlib.ExitStack() as stack:
            env = os.environ.copy()
            if temporary:
                parent = ROOT / ".scratch" / "tmp"
                parent.mkdir(parents=True, exist_ok=True)
                directory = stack.enter_context(tempfile.TemporaryDirectory(prefix="run-", dir=parent))
                env.update(TMPDIR=directory + "/", TMP=directory, TEMP=directory)
            fd, report = tempfile.mkstemp(prefix="run-", suffix=".log", dir=reports)
            log = stack.enter_context(os.fdopen(fd, "wb"))
            print(f"报告（保留 30 天）: {report}", flush=True)
            child = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, start_new_session=True)

            def forward(signum, _frame):
                if child.poll() is None:
                    os.killpg(child.pid, signum)

            previous = {s: signal.signal(s, forward) for s in (signal.SIGINT, signal.SIGTERM)}
            try:
                for data in iter(child.stdout.readline, b""):
                    log.write(data)
                    log.flush()
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                code = child.wait()
                log.write(f"\n退出码: {code}\n".encode())
                return code if code >= 0 else 128 - code
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    child.wait()
                child.stdout.close()
                for sig, handler in previous.items():
                    signal.signal(sig, handler)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--temporary", action="store_true", help="为本次测试设置退出即回收的 TMPDIR")
    parser.add_argument("--unlocked", action="store_true", help="仅供会自行调用构建锁的 Web 测试使用")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("缺少命令")
    sys.exit(run(command, args.temporary, args.unlocked))
