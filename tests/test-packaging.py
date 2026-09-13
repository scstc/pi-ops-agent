"""Exercise the actual generated installer header without downloading a model."""
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PackagingTests(unittest.TestCase):
    def test_one_click_exit_and_cleanup(self):
        source = (ROOT / "scripts/ci-build.sh").read_text()
        header = source.split("cat > \"$RUN.part\" <<'EOF'\n", 1)[1].split("\nEOF\n", 1)[0] + "\n"
        for precheck, install, expected in [(0, 0, 0), (2, 0, 0), (1, 0, 1), (0, 7, 7)]:
            with self.subTest(precheck=precheck, install=install), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                payload = io.BytesIO()
                with tarfile.open(fileobj=payload, mode="w:gz") as archive:
                    for name, script in {
                        "env-check.sh": f"#!/bin/bash\nexit {precheck}\n",
                        "install.sh": f"#!/bin/bash\nprintf installed > '{folder}/called'\nexit {install}\n",
                    }.items():
                        data = script.encode()
                        entry = tarfile.TarInfo(name)
                        entry.size, entry.mode = len(data), 0o755
                        archive.addfile(entry, io.BytesIO(data))
                installer = folder / "package.run"
                installer.write_bytes(header.encode() + payload.getvalue())
                import os
                result = subprocess.run(["bash", str(installer)], env={**os.environ, "TMPDIR": directory}, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stderr.decode())
                self.assertEqual((folder / "called").exists(), precheck != 1)
                self.assertFalse(list(folder.glob(".pi-ops-install.*")))

    def test_package_default_overrides_previously_installed_2b(self):
        source = (ROOT / "install.sh").read_text()
        selection = source.split('DEFAULT_GGUF=""\n', 1)[1].split("\n# ---------- 5.", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            bundle, models = folder / "bundle", folder / "models"
            bundle.mkdir()
            models.mkdir()
            for name in ["qwen3.5-2b", "qwen3.5-0.8b"]:
                (models / (name + ".gguf")).touch()
            (bundle / "qwen3.5-0.8b.gguf").touch()
            for declaration, expected in [("qwen3.5-0.8b", 0), ("missing", 1)]:
                (bundle / "default-model.txt").write_text(declaration)
                script = f'set -eu\nBUNDLE="{bundle}"\nPI_OPS_HOME="{folder}"\nDEFAULT_GGUF=""\ndie() {{ exit 1; }}\n' + selection + '\nprintf "%s" "$DEFAULT_ID"\n'
                result = subprocess.run(["bash", "-c", script], capture_output=True)
                self.assertEqual(result.returncode, expected)
                if expected == 0:
                    self.assertEqual(result.stdout.decode(), declaration)


if __name__ == "__main__":
    unittest.main()
