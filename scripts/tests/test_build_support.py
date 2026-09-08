#!/usr/bin/env python3
"""验证构建互斥、失败回收及报告保留边界，不运行实际编译。"""
import importlib.util
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "build-support.py"
BOOT = """
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location('support', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.ROOT = pathlib.Path(sys.argv[2])
sys.exit(m.run([sys.executable, '-c', sys.argv[3]], temporary=True))
"""


class BuildSupportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def start(self, code):
        return subprocess.Popen([sys.executable, "-B", "-c", BOOT, str(SCRIPT), str(self.root), code],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def test_failure_reclaims_only_owned_temporary_output(self):
        keep = self.root / "keep.txt"
        keep.write_text("保留")
        child = self.start("import os,pathlib,sys; pathlib.Path(os.environ['TMPDIR'],'fixture').write_text('test'); sys.exit(7)")
        self.assertEqual(child.wait(timeout=10), 7)
        self.assertEqual(list((self.root / ".scratch/tmp").iterdir()), [])
        self.assertEqual(keep.read_text(), "保留")
        report = next((self.root / ".scratch/reports").glob("run-*.log"))
        self.assertIn("退出码: 7", report.read_text())

    def test_parallel_builds_are_serialized(self):
        marker = self.root / "exclusive"
        code = f"import os,time; p={str(marker)!r}; fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY); time.sleep(.3); os.close(fd); os.unlink(p)"
        children = [self.start(code), self.start(code)]
        self.assertEqual([p.wait(timeout=10) for p in children], [0, 0])

    def test_signal_reclaims_output_and_releases_lock(self):
        ready = self.root / "ready"
        child = self.start(f"import pathlib,time; pathlib.Path({str(ready)!r}).touch(); time.sleep(30)")
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(ready.exists())
            child.send_signal(signal.SIGTERM)
            self.assertEqual(child.wait(timeout=5), 143)
            self.assertEqual(list((self.root / ".scratch/tmp").iterdir()), [])
            self.assertEqual(self.start("pass").wait(timeout=5), 0)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

    def test_retention_does_not_remove_manual_reports_or_symlinks(self):
        spec = importlib.util.spec_from_file_location("support", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        old = self.root / "run-old.log"
        manual = self.root / "manual.log"
        recent = self.root / "run-recent.log"
        for p in (old, manual, recent):
            p.touch()
        link = self.root / "run-link.log"
        link.symlink_to(manual)
        stale = time.time() - 31 * 86400
        for p in (old, manual):
            os.utime(p, (stale, stale))
        module.prune_reports(self.root, 30)
        self.assertFalse(old.exists())
        self.assertTrue(manual.exists() and recent.exists() and link.is_symlink())

    def prepare_shell_fixture(self, name, build_code):
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(SCRIPT, scripts / SCRIPT.name)
        shutil.copy2(SCRIPT.parent / name, scripts / name)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "xcodebuild"
        stub.write_text("#!/bin/bash\n" + build_code)
        stub.chmod(0o755)
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", DEVELOPER_DIR="/stub")
        return scripts / name, env

    def test_isolated_dev_cleans_home_after_build_failure(self):
        script, env = self.prepare_shell_fixture("dev.sh", "exit 7\n")
        result = subprocess.run(["bash", str(script), "--isolated"], env=env, capture_output=True)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(list((self.root / ".scratch/tmp").iterdir()), [])

    def test_isolated_dev_preserves_caller_home(self):
        script, env = self.prepare_shell_fixture("dev.sh", "exit 7\n")
        home = self.root / "caller-home"
        home.mkdir()
        (home / "fixture").touch()
        result = subprocess.run(["bash", str(script), "--isolated", str(home)], env=env, capture_output=True)
        self.assertEqual(result.returncode, 7)
        self.assertTrue((home / "fixture").exists())

    def test_archive_failure_preserves_existing_release(self):
        script, env = self.prepare_shell_fixture("archive.sh", "exit 7\n")
        dist = self.root / "dist/release"
        dist.mkdir(parents=True)
        artifact = dist / "existing.dmg"
        artifact.write_bytes(b"release")
        result = subprocess.run(["bash", str(script)], env=env, capture_output=True)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(artifact.read_bytes(), b"release")


if __name__ == "__main__":
    unittest.main()
