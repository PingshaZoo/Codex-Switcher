"""Double-click launcher; also catches package import and initialization failures."""

import os
from pathlib import Path
import re
import sys
import traceback
from datetime import datetime


def main():
    try:
        if sys.version_info < (3, 11):
            raise RuntimeError("Python 3.11 or later is required.")
        from codex_switcher.cli import main as entry
        return entry()
    except Exception:
        message = re.sub(r"sk-[\w-]+", "[REDACTED]", traceback.format_exc())
        path = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "Codex-Switcher" / "logs" / "runtime.log"
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.exists() and path.stat().st_size > 5 * 1024**2:
                os.replace(path, path.with_suffix(".log.1"))
            with path.open("a", encoding="utf-8", newline="\n") as stream:
                stream.write(datetime.now().isoformat() + " [FATAL] " + message + "\n")
        except OSError:
            pass
        print("Startup failed. Log: " + str(path), file=sys.stderr)
        print(message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
