"""Startup diagnostics, HTTP model discovery, and dependency boundaries."""

import ast
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

from codex_switcher import profiles


class EntrypointTests(unittest.TestCase):
    def test_model_discovery_preserves_base_path_and_deduplicates(self):
        body = io.BytesIO(json.dumps({"data": [{"id": "model-b"}, {"id": "model-a"}, {"id": "model-b"}]}).encode())
        opener = Mock()
        opener.open.return_value = body
        with patch("codex_switcher.profiles.build_opener", return_value=opener):
            result = profiles.fetch_models("https://example.invalid/v1/", "dummy-api-key")
        self.assertEqual(result, ["model-b", "model-a"])
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://example.invalid/v1/models")
        self.assertEqual(request.get_header("Authorization"), "Bearer dummy-api-key")

    def test_network_errors_and_response_bodies_not_exposed(self):
        opener = Mock()
        opener.open.side_effect = RuntimeError("server echoed dummy-api-key")
        with patch("codex_switcher.profiles.build_opener", return_value=opener), self.assertRaises(RuntimeError) as failure:
            profiles.fetch_models("https://example.invalid/v1", "dummy-api-key")
        self.assertNotIn("dummy-api-key", str(failure.exception))

    def test_model_discovery_rejects_empty_or_invalid_response(self):
        for value in ({"data": []}, {"models": []}, [], {"data": "wrong"}):
            opener = Mock()
            opener.open.return_value = io.BytesIO(json.dumps(value).encode())
            with patch("codex_switcher.profiles.build_opener", return_value=opener), self.assertRaises(RuntimeError):
                profiles.fetch_models("https://example.invalid", "dummy-api-key")

    def test_redirects_never_forward_authorization(self):
        self.assertIsNone(profiles.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://other.invalid"))

    def test_launcher_logs_import_failure_and_redacts(self):
        project = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="switcher-launcher-test-") as directory:
            root = Path(directory)
            shutil.copy2(project / "start_switcher.py", root / "start_switcher.py")
            package = root / "codex_switcher"
            package.mkdir()
            (package / "__init__.py").write_text("raise RuntimeError('sk-dummy-secret')\n", encoding="utf-8")
            env = {**os.environ, "LOCALAPPDATA": str(root)}
            result = subprocess.run([sys.executable, "-X", "utf8", str(root / "start_switcher.py")],
                                    cwd=root, env=env, capture_output=True)
            self.assertEqual(result.returncode, 1)
            log = (root / "Codex-Switcher" / "logs" / "runtime.log").read_text(encoding="utf-8")
            self.assertIn("[FATAL]", log)
            self.assertNotIn("sk-dummy-secret", log)
            self.assertNotIn(b"sk-dummy-secret", result.stderr)

    def test_source_runtime_has_only_standard_library_dependencies(self):
        project = Path(__file__).resolve().parents[1]
        for path in [project / "start_switcher.py", *(project / "codex_switcher").glob("*.py")]:
            with self.subTest(path=path.name):
                raw = path.read_bytes()
                self.assertFalse(raw.startswith(b"\xef\xbb\xbf"))
                self.assertNotIn(b"\r\n", raw)
                tree = ast.parse(raw.decode("utf-8"))
                for node in ast.walk(tree):
                    modules = []
                    if isinstance(node, ast.Import):
                        modules = [a.name.split(".")[0] for a in node.names]
                    elif isinstance(node, ast.ImportFrom) and not node.level:
                        modules = [node.module.split(".")[0]]
                    for name in modules:
                        self.assertIn(name, sys.stdlib_module_names | {"codex_switcher"})

    def test_double_click_entrypoints_no_longer_call_powershell(self):
        project = Path(__file__).resolve().parents[1]
        for name in ("Start.cmd", "检查当前对话.cmd"):
            text = (project / name).read_text(encoding="utf-8").lower()
            self.assertIn("start_switcher.py", text)
            self.assertNotIn("powershell", text)
            self.assertNotIn(".ps1", text)

    @unittest.skipUnless(os.name == "nt", "Windows cmd launchers")
    def test_cmd_launchers_with_temporary_codex_home(self):
        project = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="switcher-cmd-test-") as directory:
            root = Path(directory)
            (root / "config.toml").write_text("notify=[]\n", encoding="utf-8")
            env = {**os.environ, "CODEX_HOME": str(root), "LOCALAPPDATA": str(root)}
            for command in (["Start.cmd", "--version"], ["检查当前对话.cmd", "-ScanAll", "--json"]):
                result = subprocess.run([os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", *command],
                                        cwd=project, env=env, input=b"\n", capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))
                if command[0] == "Start.cmd":
                    self.assertIn(b"2.0.0", result.stdout)
                else:
                    self.assertIn(b"[]", result.stdout)


if __name__ == "__main__":
    unittest.main()
