"""Tkinter integration tests against a temporary home, with dialogs intercepted."""

from pathlib import Path
import gc
import tempfile
import time
import tkinter as tk
import unittest
from unittest.mock import patch

from codex_switcher.gui import SwitcherApp
from codex_switcher import profiles, storage


class GuiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="switcher-gui-test-")
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "config.toml"
        storage.atomic_write(self.path, 'model="gpt-example"\nnotify=[]\n')
        self.root = tk.Tk()
        self.app = SwitcherApp(self.root, self.path)
        self.root.update()
        self.addCleanup(self.cleanup_root)

    def cleanup_root(self):
        self.app._close()
        # Collect destroyed Tcl widget cycles on their owning thread before a
        # later test starts another background worker and triggers Python GC.
        self.app = None
        self.root = None
        gc.collect()

    def until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() > deadline:
                self.fail("UI operation did not finish")
            self.root.update()
            time.sleep(0.01)
        self.root.update()

    def test_layout_fits_default_and_minimum_window(self):
        for size in ("850x770", "760x700", "1050x850"):
            with self.subTest(size=size):
                self.root.geometry(size)
                self.root.update()
                for control in self.app.controls:
                    self.assertTrue(control.winfo_ismapped(), str(control))
                    self.assertGreater(control.winfo_width(), 20)
                    self.assertGreaterEqual(control.winfo_rooty(), self.root.winfo_rooty())
                    self.assertLessEqual(control.winfo_rooty() + control.winfo_height(), self.root.winfo_rooty() + self.root.winfo_height())
        self.assertFalse(self.app.migrate.get())

    def test_save_edit_and_switch_share_services(self):
        self.app._new()
        for name, value in {"id": "vendor_a", "name": "测试供应商", "baseUrl": "https://example.invalid/v1", "models": "model-a, model-b", "key": "dummy-gui-secret"}.items():
            self.app.fields[name].set(value)
        self.app._save()
        self.until(lambda: not self.app.busy)
        self.assertEqual(self.app.fields["key"].get(), "")
        self.assertEqual(self.app.fields["id"].get(), "vendor_a")
        self.assertEqual(storage.read_text(self.path), 'model="gpt-example"\nnotify=[]\n')
        with patch("codex_switcher.profiles.assert_closed"), patch("codex_switcher.gui.messagebox.showinfo") as dialog:
            self.app._switch(False)
            self.until(lambda: not self.app.busy)
            dialog.assert_called_once()
        self.assertIn('model_provider = "vendor_a"', storage.read_text(self.path))
        self.assertEqual(str(self.app.entries["id"]["state"]), "readonly")

    def test_async_error_reenables_controls(self):
        errors = []
        def fail():
            raise ValueError("dummy failure")
        with patch.object(self.app, "_error", side_effect=errors.append):
            self.app._task(fail, lambda result: self.fail("unexpected success"))
            self.until(lambda: not self.app.busy)
        self.assertEqual(len(errors), 1)
        self.assertEqual(str(self.app.profiles["state"]), "readonly")
        self.assertEqual(str(self.app.config_entry["state"]), "normal")

    def test_changed_config_path_cannot_apply_stale_profile(self):
        self.app.config.set(str(self.path.with_name("other.toml")))
        with self.assertRaisesRegex(ValueError, "重新加载"):
            self.app._draft()

    def test_monitor_refresh_pause_and_close(self):
        self.app._open_monitor()
        window = self.app.monitor
        self.until(lambda: not window.busy)
        self.assertIn("未找到", window.headline.get())
        window.toggle()
        self.assertTrue(window.paused)
        self.assertIsNone(window.timer)
        window.full.set(True)
        window.refresh()
        self.until(lambda: not window.busy)
        window.close()
        self.assertFalse(window.window.winfo_exists())


if __name__ == "__main__":
    unittest.main()
