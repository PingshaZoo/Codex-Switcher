"""Atomic writes, recoverable file transactions, locking, and redacted diagnostics."""

from __future__ import annotations

import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import re
import shutil
import tempfile
from datetime import datetime
import uuid


def read_text(path: Path) -> str:
    return Path(path).read_text(encoding="utf-8-sig")


def read_json(path: Path, default=None):
    return json.loads(read_text(path)) if Path(path).is_file() else default


def atomic_write(path: Path, data: str | bytes) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data.encode("utf-8") if isinstance(data, str) else data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def write_json(path: Path, value) -> None:
    atomic_write(path, json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n")


def fingerprint(path: Path) -> str | None:
    if not path.exists():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def operation_id() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S-%f") + "-" + uuid.uuid4().hex[:8]


class FileTransaction:
    """Capture files before mutation; backups remain available after either outcome."""

    def __init__(self, root: Path, paths):
        self.root = root
        root.mkdir(parents=True, exist_ok=False)
        self.files = []
        for path in dict.fromkeys(Path(p).resolve() for p in paths):
            backup = root / f"file-{len(self.files)}"
            existed = path.is_file()
            if existed:
                shutil.copy2(path, backup)
            self.files.append({"path": str(path), "backup": str(backup), "existed": existed})
        write_json(root / "files.json", self.files)

    def restore(self):
        errors = []
        for entry in reversed(self.files):
            try:
                target = Path(entry["path"])
                if entry["existed"]:
                    atomic_write(target, Path(entry["backup"]).read_bytes())
                else:
                    target.unlink(missing_ok=True)
            except OSError as exc:
                errors.append(f"{entry['path']}: {exc}")
        if errors:
            raise RuntimeError("文件恢复失败；保留备份：" + str(self.root) + "\n" + "\n".join(errors))


class SwitchLock:
    """OS-owned lock: a process crash releases it without deleting a shared inode."""

    def __init__(self, directory: Path):
        self.path = directory / "switch.lock"
        self.stream = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.stream = self.path.open("a+b")
        try:
            if self.path.stat().st_size == 0:
                self.stream.write(b"\0")
                self.stream.flush()
            self.stream.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            self.stream.close()
            self.stream = None
            raise RuntimeError("另一个切换操作正在进行，请稍后重试。") from exc
        return self

    def __exit__(self, *args):
        if self.stream:
            try:
                if os.name == "nt":
                    import msvcrt
                    self.stream.seek(0)
                    msvcrt.locking(self.stream.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(self.stream.fileno(), fcntl.LOCK_UN)
            finally:
                self.stream.close()
                self.stream = None


class RedactingFormatter(logging.Formatter):
    def __init__(self, secrets=()):
        super().__init__("%(asctime)s [%(levelname)s] pid=%(process)d %(message)s")
        self.secrets = [s for s in secrets if s]

    def format(self, record):
        text = super().format(record)
        for secret in sorted(self.secrets, key=len, reverse=True):
            text = text.replace(secret, "[REDACTED]")
        text = re.sub(r"sk-[\w-]+", "[REDACTED]", text)
        return re.sub(r"(?i)(Bearer\s+)\S+", r"\1[REDACTED]", text)


def diagnostic_logger(directory: Path | None = None, secrets=()):
    fallback = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "Codex-Switcher" / "logs"
    for candidate in dict.fromkeys([directory, fallback]):
        if candidate is None:
            continue
        try:
            candidate.mkdir(parents=True, exist_ok=True)
            handler = RotatingFileHandler(candidate / "runtime.log", maxBytes=5 * 1024**2,
                                         backupCount=1, encoding="utf-8")
            handler.setFormatter(RedactingFormatter(secrets))
            logger = logging.Logger("codex-switcher", level=logging.INFO)
            logger.addHandler(handler)
            return logger
        except OSError:
            continue
    logger = logging.Logger("codex-switcher")
    logger.addHandler(logging.NullHandler())
    return logger


def close_logger(logger):
    for handler in logger.handlers[:]:
        handler.close()
        logger.removeHandler(handler)
