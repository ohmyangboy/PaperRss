#!/usr/bin/env python3
"""验证构建泳道互斥、缓存回收、失败回收及报告保留边界，不运行实际编译。"""
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
sys.exit(m.run([sys.executable, '-c', sys.argv[3]], temporary=True, lane=sys.argv[4]))
"""


def load_module():
    spec = importlib.util.spec_from_file_location("support", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BuildSupportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def start(self, code, lane="all"):
        return subprocess.Popen([sys.executable, "-B", "-c", BOOT, str(SCRIPT), str(self.root), code, lane],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    @staticmethod
    def hold_code(marker, seconds=0.6):
        return (f"import os,time; p={str(marker)!r}; "
                f"fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY); time.sleep({seconds}); os.close(fd); os.unlink(p)")

    @staticmethod
    def wait_for(path, timeout=5):
        deadline = time.monotonic() + timeout
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        return path.exists()

    @staticmethod
    def make_stale(path, days=40):
        stamp = time.time() - days * 86400
        for directory, dirnames, filenames in os.walk(path):
            for name in filenames + dirnames:
                os.utime(os.path.join(directory, name), (stamp, stamp))
            os.utime(directory, (stamp, stamp))

    def test_failure_reclaims_only_owned_temporary_output(self):
        keep = self.root / "keep.txt"
        keep.write_text("保留")
        child = self.start("import os,pathlib,sys; pathlib.Path(os.environ['TMPDIR'],'fixture').write_text('test'); sys.exit(7)")
        self.assertEqual(child.wait(timeout=10), 7)
        self.assertEqual(list((self.root / ".scratch/tmp").iterdir()), [])
        self.assertEqual(keep.read_text(), "保留")
        report = next((self.root / ".scratch/reports").glob("run-*.log"))
        self.assertIn("退出码: 7", report.read_text())

    def test_same_lane_builds_are_serialized(self):
        marker = self.root / "exclusive"
        children = [self.start(self.hold_code(marker, 0.3), lane="app"),
                    self.start(self.hold_code(marker, 0.3), lane="app")]
        self.assertEqual([p.wait(timeout=10) for p in children], [0, 0])

    def test_app_and_tests_lanes_run_in_parallel(self):
        app_marker = self.root / "app-hold"
        tests_marker = self.root / "tests-hold"
        app = self.start(self.hold_code(app_marker), lane="app")
        self.assertTrue(self.wait_for(app_marker))
        tests = self.start(self.hold_code(tests_marker), lane="tests")
        try:
            self.assertTrue(self.wait_for(tests_marker), "tests 泳道应能与 app 泳道同时持锁")
        finally:
            for child in (app, tests):
                if child.poll() is None:
                    child.kill()
                child.wait()

    def test_all_lane_waits_for_both_lanes(self):
        marker = self.root / "tests-hold"
        tests = self.start(self.hold_code(marker), lane="tests")
        self.assertTrue(self.wait_for(marker))
        release = self.start("pass", lane="all")
        deadline = time.monotonic() + 5
        try:
            while marker.exists() and time.monotonic() < deadline:
                self.assertIsNone(release.poll(), "all 泳道不应在 tests 泳道释放前完成")
                time.sleep(0.02)
            self.assertFalse(marker.exists(), "tests 泳道未按时释放")
            self.assertEqual(release.wait(timeout=5), 0)
        finally:
            for child in (tests, release):
                if child.poll() is None:
                    child.kill()
                    child.wait()

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
        module = load_module()
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

    def test_cleanup_reclaims_only_stale_generated_caches(self):
        build = self.root / "build"
        isolated = build / "isolated"
        (isolated / "Build").mkdir(parents=True)
        (isolated / "info.plist").write_text("{}")
        self.make_stale(isolated)

        fresh = build / "Build"
        fresh.mkdir()
        (fresh / "recent").write_text("x")

        materials = build / "visual-verification"
        (materials / "before").mkdir(parents=True)
        (materials / "before" / "shot.png").write_bytes(b"png")
        self.make_stale(materials)
        escaped = build / "material-link"
        escaped.symlink_to(materials)

        locks = build / ".locks"
        locks.mkdir()
        (locks / "app.lock").write_text("")
        self.make_stale(locks)

        swiftpm = self.root / ".build"
        swiftpm.mkdir()
        (swiftpm / "workspace-state.json").write_text("{}")
        self.make_stale(swiftpm)

        module = load_module()
        eligible = {path.relative_to(self.root) for path, _, _ in module.collect_reclaimable(self.root, 7)}
        self.assertEqual(eligible, {Path("build/isolated"), Path(".build")})

        self.assertEqual(module.run_clean(self.root, 7, apply=False), 0)
        self.assertTrue(isolated.exists() and swiftpm.exists())

        self.assertEqual(module.run_clean(self.root, 7, apply=True), 0)
        self.assertFalse(isolated.exists())
        self.assertFalse(swiftpm.exists())
        self.assertTrue(materials.exists())
        self.assertTrue(fresh.exists())
        self.assertTrue((locks / "app.lock").exists())
        self.assertTrue(escaped.is_symlink())

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
