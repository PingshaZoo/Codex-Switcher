"""Manual visual QA preview. Uses disposable sample data, never the real Codex home."""

from pathlib import Path
import sys
import tempfile
import tkinter as tk

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from codex_switcher import profiles, storage
from codex_switcher.gui import SwitcherApp


def main():
    with tempfile.TemporaryDirectory(prefix="switcher-preview-") as directory:
        config = Path(directory) / "config.toml"
        storage.atomic_write(config, 'model="gpt-example"\nnotify=[]\n')
        store = profiles.load_store(config)
        profiles.set_profile(store, profiles.new_profile("example", "示例供应商", "https://example.invalid/v1", "example-chat, example-reasoner", "dummy-preview-key"))
        profiles.save_store(config, store)
        root = tk.Tk()
        app = SwitcherApp(root, config)
        app.profiles.current(1)
        app._select()
        root.mainloop()


if __name__ == "__main__":
    main()
