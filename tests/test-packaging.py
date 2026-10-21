"""Exercise the actual generated installer header without downloading a model."""
import io
import json
import hashlib
import re
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PackagingTests(unittest.TestCase):
    def test_spark_fetch_selects_bf16_and_upgrades_cached_pi_without_network(self):
        version = re.search(r'^PI_VER="([^"]+)"', (ROOT / "fetch-bundle.sh").read_text(), re.M).group(1)
        for previous in ("pi 0.85.1", "pi " + version):
            with self.subTest(previous=previous), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                bundle = folder / "bundle"
                bundle.mkdir()
                (folder / "fetch-bundle.sh").write_bytes((ROOT / "fetch-bundle.sh").read_bytes())
                (bundle / "llama-cached-bin-ubuntu-x64.tar.gz").touch()
                (bundle / "spark-x2.5-1.7b.gguf").write_bytes(b"GGUFbf16")
                (bundle / "qwen3.5-2b.gguf").write_bytes(b"GGUFqwen")
                (bundle / "pi-bundle.tar.gz").write_bytes(b"old-pi")
                (bundle / "pi-version.txt").write_text(previous + "\n")
                node = f'#!/bin/sh\necho "pi {version}"\n'.encode()
                npm = b'#!/bin/sh\necho "$*" >> "$PWD/npm-calls"\nprintf "{}" > package.json\nprintf "{}" > package-lock.json\nmkdir -p node_modules\n'
                with tarfile.open(bundle / "node-v22-test-linux-x64.tar.xz", "w:xz") as archive:
                    for name, data in (("node", node), ("npm", npm)):
                        entry = tarfile.TarInfo("node-v22-test/bin/" + name)
                        entry.size, entry.mode = len(data), 0o755
                        archive.addfile(entry, io.BytesIO(data))
                result = subprocess.run(["bash", str(folder / "fetch-bundle.sh"), "--model", "spark-x2.5-1.7b"],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((bundle / "default-model.txt").read_text(), "spark-x2.5-1.7b\n")
                self.assertIn("spark-x2.5-1.7b.gguf", (bundle / "MANIFEST.sha256").read_text())
                self.assertEqual((bundle / "pi-version.txt").read_text(), "pi " + version + "\n")
                if previous != "pi " + version:
                    calls = (folder / ".tools/stage/npm-calls").read_text()
                    self.assertIn("@earendil-works/pi-coding-agent@" + version, calls)
                    with tarfile.open(bundle / "pi-bundle.tar.gz") as archive:
                        self.assertIn("node_modules", archive.getnames())
                else:
                    self.assertEqual((bundle / "pi-bundle.tar.gz").read_bytes(), b"old-pi")

    def test_model_contexts_match_generated_server_and_preserve_settings(self):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")
        policy = 'context_for_model() {' + source.split('context_for_model() {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
        models_block = source.split('backup "$PI_DIR/models.json"\n', 1)[1].split('\nlog ', 1)[0]
        launcher_block = source.split('cat > "$PI_OPS_HOME/bin/llama-run" <<EOF\n', 1)[1].split('\nEOF\n', 1)[0]
        code = source.split('"$NODE" -e \'\n', 1)[1].split("\n' \"$PI_DIR/settings.json\"", 1)[0]
        expected = {"qwen3.5-0.8b": 65536, "qwen3.5-2b": 65536, "qwen3.5-4b": 65536,
                    "spark-x2.5-1.7b": 1048576, "custom-model": 16384}
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "models").mkdir()
            (folder / "llama.key").write_text("test-key")
            fake_llama = folder / "fake-llama"
            fake_llama.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            fake_llama.chmod(0o755)
            for model_id in expected:
                (folder / "models" / (model_id + ".gguf")).touch()
            script = f'set -euo pipefail\nPI_OPS_HOME="{folder}"\nPI_DIR="{folder}"\nPORT=8787\nLLAMA_KEY=test-key\n' + policy + models_block
            subprocess.run(["bash", "-c", script], check=True)
            models = json.loads((folder / "models.json").read_text())["providers"]["llama-cpp"]["models"]
            self.assertEqual({model["id"]: model["contextWindow"] for model in models}, expected)
            # The generated launcher must stay aligned even after switching MODEL
            # between a previously installed Qwen and a new Spark package.
            for default_id in ("spark-x2.5-1.7b", "qwen3.5-2b"):
                script = f'set -euo pipefail\nPI_OPS_HOME="{folder}"\nLLAMA_DIR="{folder}"\nLLAMA_BIN="{fake_llama}"\nKEY_FILE="{folder}/llama.key"\nPORT=8787\nDEFAULT_GGUF="{folder}/models/{default_id}.gguf"\n' + policy
                script += "cat > \"$PI_OPS_HOME/llama-run\" <<EOF\n" + launcher_block + "\nEOF\n"
                subprocess.run(["bash", "-c", script], check=True)
                for model_id, context in expected.items():
                    with self.subTest(default=default_id, selected=model_id):
                        run = f'MODEL="{folder}/models/{model_id}.gguf" bash "{folder}/llama-run"'
                        args = subprocess.check_output(["bash", "-c", run], text=True).splitlines()
                        self.assertEqual(int(args[args.index("-c") + 1]), context)
                        self.assertEqual(args[args.index("--parallel") + 1], "1")
            settings_file = folder / "settings.json"
            settings_file.write_text(json.dumps({"theme": "dark", "compaction": {"enabled": False, "keepRecentTokens": 20000}}))
            subprocess.run(["node", "-e", code, str(settings_file), "spark-x2.5-1.7b"], check=True)
            settings = json.loads(settings_file.read_text())
        self.assertTrue(settings["compaction"]["enabled"])
        self.assertEqual(settings["theme"], "dark")
        reserve = settings["compaction"]["reserveTokens"]
        for model in models:
            self.assertLess(model["maxTokens"], reserve)
            self.assertLess(reserve, model["contextWindow"])
            self.assertLess(settings["compaction"]["keepRecentTokens"], model["contextWindow"] - reserve)
            self.assertLess(settings["branchSummary"]["reserveTokens"], model["contextWindow"])

    def test_one_click_exit_and_cleanup(self):
        source = (ROOT / "scripts/ci-build.sh").read_text(encoding="utf-8")
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
                checked_header = header.replace('__PI_OPS_PAYLOAD_SHA256__', hashlib.sha256(payload.getvalue()).hexdigest())
                installer.write_bytes(checked_header.encode() + payload.getvalue())
                import os
                result = subprocess.run(["bash", str(installer)], env={**os.environ, "TMPDIR": directory}, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stderr.decode())
                self.assertEqual((folder / "called").exists(), precheck != 1)
                self.assertFalse(list(folder.glob(".pi-ops-install.*")))
                if precheck == 0 and install == 0:
                    (folder / "called").unlink()
                    installer.write_bytes(installer.read_bytes()[:-8])
                    broken = subprocess.run(["bash", str(installer)], env={**os.environ, "TMPDIR": directory}, capture_output=True)
                    self.assertNotEqual(broken.returncode, 0)
                    self.assertFalse((folder / "called").exists())

    def test_install_rejects_server_context_smaller_than_advertised(self):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")
        policy = 'context_for_model() {' + source.split('context_for_model() {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
        check = 'ACTUAL_CONTEXT=' + source.split('ACTUAL_CONTEXT=', 1)[1].split('\nlog "冒烟:chat', 1)[0]
        for model_id, actual, expected in [("spark-x2.5-1.7b", 1048576, 0),
                                           ("spark-x2.5-1.7b", 16384, 1),
                                           ("qwen3.5-2b", 65536, 0),
                                           ("qwen3.5-2b", 16384, 1)]:
            with self.subTest(model=model_id, actual=actual), tempfile.TemporaryDirectory() as directory:
                response = Path(directory) / "models.json"
                response.write_text(json.dumps({"data": [{"id": model_id, "meta": {"n_ctx": actual}}]}))
                script = f'set -euo pipefail\nNODE=node\nDEFAULT_ID="{model_id}"\nLLAMA_KEY=test-key\nPORT=8787\ncurl() {{ cat "{response}"; }}\nlog() {{ :; }}\ndie() {{ exit 1; }}\n' + policy + check
                result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_reinstall_repairs_same_size_and_larger_corrupt_models(self):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")
        copying = source.split('for g in "$BUNDLE"/*.gguf; do\n', 1)[1].split('\ndone\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            bundle, models = folder / "bundle", folder / "models"
            bundle.mkdir()
            models.mkdir()
            name = 'qwen3.5-0.8b.gguf'
            (bundle / name).write_bytes(b'GGUFgood')
            for old in [b'GGUFxxxx', b'GGUFxxxxxxxxxxxx']:
                (models / name).write_bytes(old)
                script = f'set -eu\nBUNDLE="{bundle}"\nPI_OPS_HOME="{folder}"\nlog() {{ :; }}\ndie() {{ exit 1; }}\ngguf_ok() {{ :; }}\ng="$BUNDLE/{name}"\n' + copying
                result = subprocess.run(['bash', '-c', script], capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertEqual((models / name).read_bytes(), b'GGUFgood')

    def test_package_default_overrides_previously_installed_2b(self):
        source = (ROOT / "install.sh").read_text(encoding="utf-8")
        selection = source.split('DEFAULT_GGUF=""\n', 1)[1].split("\n# ---------- 5.", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            bundle, models = folder / "bundle", folder / "models"
            bundle.mkdir()
            models.mkdir()
            for name in ["qwen3.5-2b", "qwen3.5-0.8b", "spark-x2.5-1.7b"]:
                (models / (name + ".gguf")).touch()
            (bundle / "qwen3.5-0.8b.gguf").touch()
            (bundle / "spark-x2.5-1.7b.gguf").touch()
            for declaration, expected in [("qwen3.5-0.8b", 0), ("spark-x2.5-1.7b", 0), ("missing", 1)]:
                (bundle / "default-model.txt").write_text(declaration)
                script = f'set -eu\nBUNDLE="{bundle}"\nPI_OPS_HOME="{folder}"\nDEFAULT_GGUF=""\ndie() {{ exit 1; }}\n' + selection + '\nprintf "%s" "$DEFAULT_ID"\n'
                result = subprocess.run(["bash", "-c", script], capture_output=True)
                self.assertEqual(result.returncode, expected)
                if expected == 0:
                    self.assertEqual(result.stdout.decode(), declaration)


if __name__ == "__main__":
    unittest.main()
