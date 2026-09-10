#!/usr/bin/env python3
"""按泳道串行执行构建/测试，按需回收构建缓存，并只轮转本工具创建的报告。"""

import argparse
import contextlib
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent

# 泳道决定入口之间的互斥范围：app 写入 build/，tests 写入 .build/，
# all 按 app → tests 的固定顺序同时锁定两条泳道，供归档/发布等全局独占入口使用。
LANES = {
    "app": ("app",),
    "tests": ("tests",),
    "all": ("app", "tests"),
}
DEFAULT_LANE = "all"

# 主 DerivedData 的顶层编译缓存（build/ 根不整体删除，避免误删素材）。
DERIVED_DATA_COMPONENTS = (
    "Build",
    "CompilationCache.noindex",
    "Debug-iphonesimulator",
    "EagerLinkingTBDs",
    "ExplicitPrecompiledModules",
    "Index.noindex",
    "Logs",
    "ModuleCache.noindex",
    "Release",
    "SDKExplicitPrecompiledModules",
    "SDKStatCaches.noindex",
    "SharedPrecompiledHeaders",
    "SourcePackages",
    "SwiftExplicitPrecompiledModules",
    "XCBuildData",
    "info.plist",
)
# 脚本自有的固定 DerivedData 根，按整目录回收。
OWNED_BUILD_DIRS = ("isolated", "archive", "upgrade", "FreshLaunchTest")


def prune_reports(directory, days):
    cutoff = time.time() - days * 86400
    for path in directory.glob("run-*.log"):
        try:
            if path.is_symlink() or not path.is_file() or path.stat().st_mtime >= cutoff:
                continue
            path.unlink()
        except FileNotFoundError:
            continue


def human_size(size):
    value = float(size)
    for unit in ("B", "KiB", "MiB"):
        if value < 1024:
            return f"{value:.0f}{unit}" if unit == "B" else f"{value:.1f}{unit}"
        value /= 1024
    return f"{value:.1f}GiB"


def tree_stats(path):
    """返回构建缓存的 (字节数, 最新修改时间)，不跟随符号链接。"""
    if path.is_file():
        stat = path.stat()
        return stat.st_size, stat.st_mtime
    size = 0
    latest = 0.0
    for directory, _names, filenames in os.walk(path):
        try:
            latest = max(latest, os.stat(directory).st_mtime)
        except OSError:
            pass
        for name in filenames:
            try:
                stat = os.stat(os.path.join(directory, name), follow_symlinks=False)
            except OSError:
                continue
            size += stat.st_size
            latest = max(latest, stat.st_mtime)
    return size, latest


def is_derived_data(path):
    return path.is_dir() and (path / "info.plist").is_file() and any(
        (path / name).is_dir() for name in ("Build", "Logs", "XCBuildData")
    )


def collect_reclaimable(store, keep_days):
    """列出超过保留期、可安全重建的构建缓存；隐藏锁与素材目录不参与。"""
    cutoff = time.time() - keep_days * 86400
    targets = []
    build = store / "build"
    if build.is_dir():
        for child in sorted(build.iterdir()):
            if child.is_symlink() or child.name.startswith("."):
                continue
            if child.name in OWNED_BUILD_DIRS or is_derived_data(child):
                targets.append(child)
            elif child.name in DERIVED_DATA_COMPONENTS or child.name.endswith(".build"):
                targets.append(child)
    swiftpm = store / ".build"
    if not swiftpm.is_symlink() and (
        (swiftpm / "workspace-state.json").is_file() or (swiftpm / "checkouts").is_dir()
    ):
        targets.append(swiftpm)
    eligible = []
    for target in targets:
        try:
            size, latest = tree_stats(target)
        except OSError:
            continue
        if latest < cutoff:
            eligible.append((target, size, latest))
    return eligible


def run_clean(store, keep_days, apply):
    eligible = collect_reclaimable(store, keep_days)
    if not eligible:
        print(f"没有超过 {keep_days} 天未改动的可回收构建缓存。")
        return 0
    total = sum(size for _, size, _ in eligible)
    action = "回收" if apply else "可回收"
    print(f"{action}构建缓存（保留最近 {keep_days} 天改动，共 {human_size(total)}）：")
    failed = 0
    for path, size, latest in sorted(eligible, key=lambda item: item[1], reverse=True):
        label = path.relative_to(store)
        if not apply:
            age = int((time.time() - latest) / 86400)
            print(f"  {label}  {human_size(size)}  最近改动 {age} 天前")
            continue
        try:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
            print(f"  已回收 {label}  {human_size(size)}")
        except OSError as error:
            failed += 1
            print(f"  回收失败 {label}: {error}", file=sys.stderr)
    if not apply:
        print("以上仅为预览，确认后运行 ./scripts/clean.sh --apply 执行回收。")
    return 1 if failed else 0


def run(command, temporary=False, unlocked=False, lane=DEFAULT_LANE):
    state = ROOT / "build"
    reports = ROOT / ".scratch" / "reports"
    state.mkdir(exist_ok=True)
    reports.mkdir(parents=True, exist_ok=True)
    locks = []
    if not unlocked:
        locks_dir = state / ".locks"
        locks_dir.mkdir(exist_ok=True)
        print(f"等待 PaperRss 构建锁（泳道 {' → '.join(LANES[lane])}）…", flush=True)
        # 不删除锁文件：所有等待者必须始终锁定同一个 inode。
        for name in LANES[lane]:
            handle = (locks_dir / f"{name}.lock").open("a")
            fcntl.flock(handle, fcntl.LOCK_EX)
            locks.append(handle)
    try:
        prune_reports(reports, 30)
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
    finally:
        for handle in reversed(locks):
            handle.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane", choices=tuple(LANES), default=DEFAULT_LANE,
                        help="锁定泳道：app 写 build/，tests 写 .build/，all 同时锁定两条（默认）")
    parser.add_argument("--temporary", action="store_true", help="为本次测试设置退出即回收的 TMPDIR")
    parser.add_argument("--unlocked", action="store_true", help="仅供会自行调用构建锁的 Web 测试使用")
    parser.add_argument("--clean", action="store_true", help="预览或回收可重建的构建缓存")
    parser.add_argument("--apply", action="store_true", help="与 --clean 搭配，真正执行回收")
    parser.add_argument("--keep-days", type=int, default=7, metavar="N",
                        help="与 --clean 搭配，保留最近 N 天有改动的缓存（默认 7）")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.clean:
        if args.keep_days < 0:
            parser.error("--keep-days 不能为负数")
        sys.exit(run_clean(ROOT, args.keep_days, args.apply))
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("缺少命令")
    sys.exit(run(command, args.temporary, args.unlocked, args.lane))
