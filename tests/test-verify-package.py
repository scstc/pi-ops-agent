"""Black-box tests for scripts/verify-package.py using tiny synthetic packages."""

import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "scripts" / "verify-package.py"
MODEL = "qwen3.5-2b"


def tar_bytes(mode, files, links=(), root_dot=False):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode=mode) as archive:
        if root_dot:
            root = tarfile.TarInfo(".")
            root.type, root.mode = tarfile.DIRTYPE, 0o755
            archive.addfile(root)
        for name, data in files.items():
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode = len(data), 0o755
            archive.addfile(entry, io.BytesIO(data))
        for name, target in links:
            entry = tarfile.TarInfo(name)
            entry.type, entry.linkname, entry.mode = tarfile.SYMTYPE, target, 0o777
            archive.addfile(entry)
    return output.getvalue()


def make_package(path, model=MODEL, mutate=None, run=False, corrupt_manifest=False):
    node = tar_bytes("w:xz", {
        "node-v22/bin/node": b"node",
        "node-v22/lib/libstdc++.so.6": b"stdc++",
        "node-v22/lib/libgcc_s.so.1": b"gcc",
        "node-v22/lib/node_modules/npm/bin/npm-cli.js": b"npm",
    }, links=(("node-v22/bin/npm", "../lib/node_modules/npm/bin/npm-cli.js"),))
    llama = tar_bytes(
        "w:gz", {"llama-server": b"server", "libgomp.so.1": b"gomp"}, root_dot=True)
    files = {
        "install.sh": b"#!/usr/bin/env bash\nexit 0\n",
        "uninstall.sh": b"#!/usr/bin/env bash\nexit 0\n",
        "env-check.sh": b"#!/usr/bin/env bash\nexit 0\n",
        "assets/SYSTEM.md": b"system\n",
        "assets/bin/idle-stop.sh": b"#!/usr/bin/env bash\nexit 0\n",
        "assets/bin/pi-ops-verify": b"#!/usr/bin/env bash\nexit 0\n",
        "assets/extensions/ops-tools.ts": b"export {};\n",
        "assets/lib/verify-check.js": b"export {};\n",
        "bundle/default-model.txt": (model + "\n").encode(),
        "bundle/{}.gguf".format(model): b"GGUFtiny-model",
        "bundle/node-v22-linux-x64.tar.xz": node,
        "bundle/llama-demo.tar.gz": llama,
        "bundle/pi-bundle.tar.gz": b"pi",
        "bundle/pi-version.txt": b"1.0.0\n",
    }
    if mutate:
        mutate(files)
    lines = []
    for name in sorted(key for key in files if key.startswith("bundle/")):
        lines.append("{}  ./{}\n".format(
            hashlib.sha256(files[name]).hexdigest(), name[len("bundle/"):]))
    files["bundle/MANIFEST.sha256"] = "".join(lines).encode()
    if corrupt_manifest:
        files["bundle/{}.gguf".format(model)] = b"GGUFtampered-after-manifest"
    payload = tar_bytes("w:gz", files)
    if run:
        path.write_bytes(b"#!/usr/bin/env bash\n__PI_OPS_PAYLOAD_BELOW__\n" + payload)
    else:
        path.write_bytes(payload)


class VerifyPackageTests(unittest.TestCase):
    def test_accepts_forward_library_symlink_chain(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package.tar.gz"
            llama = tar_bytes("w:gz", {
                "llama-server": b"server", "libgomp.so.1": b"gomp",
                "libggml.so.0.23.0": b"ggml",
            }, links=(("libggml.so", "libggml.so.0"),
                      ("libggml.so.0", "libggml.so.0.23.0")))
            make_package(package, mutate=lambda files: files.update({"bundle/llama-demo.tar.gz": llama}))
            result = self.check(package)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_library_symlink_cycle(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package.tar.gz"
            llama = tar_bytes("w:gz", {"llama-server": b"server", "libgomp.so.1": b"gomp"},
                              links=(("libggml.so", "libggml.so.0"),
                                     ("libggml.so.0", "libggml.so")))
            make_package(package, mutate=lambda files: files.update({"bundle/llama-demo.tar.gz": llama}))
            result = self.check(package)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("link cycle", result.stderr)

    def check(self, package, model=MODEL):
        return subprocess.run(
            [sys.executable, str(VERIFY), str(package), "--model", model],
            capture_output=True, text=True,
        )

    def test_accepts_valid_tar_and_run_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for name, run in (("package.tar.gz", False), ("package.run", True)):
                package = folder / name
                make_package(package, run=run)
                result = self.check(package)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("OK:", result.stdout)

    def test_rejects_requested_model_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package.tar.gz"
            make_package(package)
            result = self.check(package, "qwen3.5-0.8b")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("expected exactly", result.stderr)

    def test_rejects_missing_required_file(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package.tar.gz"
            make_package(package, mutate=lambda files: files.pop("uninstall.sh"))
            result = self.check(package)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing required file", result.stderr)

    def test_rejects_manifest_hash_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package.tar.gz"
            make_package(package, corrupt_manifest=True)
            result = self.check(package)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SHA-256 mismatch", result.stderr)

    def test_rejects_truncated_run_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package.run"
            make_package(package, run=True)
            package.write_bytes(package.read_bytes()[:-12])
            result = self.check(package)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("truncated", result.stderr)

    def test_rejects_outer_path_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "package.tar.gz"
            make_package(package, mutate=lambda files: files.__setitem__("../outside", b"no"))
            result = self.check(package)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsafe tar member path", result.stderr)


if __name__ == "__main__":
    unittest.main()
