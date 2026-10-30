"""Streaming JSONL migration and SQLite backup/restore with fork offset repair."""

from __future__ import annotations

from contextlib import closing
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import tempfile
import time

from .storage import atomic_write, fingerprint, write_json

TOOL_TYPES = frozenset({"function_call", "function_call_output", "custom_tool_call",
    "custom_tool_call_output", "tool_search_call", "tool_search_output"})
PROJECTION_TABLES = ("thread_items", "thread_turns", "thread_history_projection_state", "thread_realtime_items")


def rollout_files(home: Path) -> list[Path]:
    return sorted(p for name in ("sessions", "archived_sessions")
                  for p in (home / name).rglob("rollout-*.jsonl") if p.is_file())


def header(path: Path) -> dict:
    with path.open("rb") as stream:
        raw = stream.readline()
    if not raw:
        raise ValueError("文件是空的")
    try:
        record = json.loads(raw)
    except (ValueError, UnicodeError) as exc:
        raise ValueError("会话文件首行不是有效 JSON") from exc
    if not isinstance(record, dict) or record.get("type") != "session_meta":
        raise ValueError("首行不是 session_meta 记录")
    payload = record.get("payload")
    if not isinstance(payload, dict) or not isinstance(payload.get("model_provider"), str):
        raise ValueError("缺少 session_meta.model_provider")
    return payload


def update_record(record: dict, provider: str, model: str, effort: str) -> tuple[int, int]:
    route, compatibility = 0, 0

    def set_existing(node, key, value):
        nonlocal route
        if isinstance(node, dict) and key in node and node[key] != value:
            node[key] = value
            route += 1

    def settings(node):
        if isinstance(node, dict):
            set_existing(node, "model", model)
            set_existing(node, "reasoning_effort", effort)

    payload = record.get("payload", {})
    kind = record.get("type", "").lower() if isinstance(record.get("type"), str) else ""
    if isinstance(payload, dict):
        if kind == "session_meta":
            set_existing(payload, "model_provider", provider)
        elif kind == "turn_context":
            set_existing(payload, "model", model)
            set_existing(payload, "effort", effort)
            settings(payload.get("collaboration_mode", {}).get("settings")
                     if isinstance(payload.get("collaboration_mode"), dict) else None)
        elif kind == "event_msg" and payload.get("type") == "thread_settings_applied":
            node = payload.get("thread_settings")
            settings(node)
            set_existing(node, "model_provider_id", provider)
            if provider != "openai":
                set_existing(node, "service_tier", None)
            if isinstance(node, dict) and isinstance(node.get("collaboration_mode"), dict):
                settings(node["collaboration_mode"].get("settings"))
        elif kind == "world_state":
            node = payload.get("state")
            set_existing(node, "model", model)
            if isinstance(node, dict):
                set_existing(node.get("collaboration_mode"), "model", model)
                set_existing(node.get("personality"), "model", model)
        elif kind == "compacted":
            metadata = payload.get("resume_metadata")
            node = metadata.get("previous_turn_settings") if isinstance(metadata, dict) else None
            settings(node)
            set_existing(node, "model_provider_id", provider)

    # An explicit stack avoids recursion limits on deeply nested tool results.
    pending = [record]
    while pending:
        node = pending.pop()
        if isinstance(node, list):
            pending.extend(node)
        elif isinstance(node, dict):
            node_type = node.get("type")
            if isinstance(node_type, str) and node_type.lower() == "reasoning":
                for key in ("encrypted_content", "id"):
                    if key in node:
                        del node[key]
                        compatibility += 1
                if provider == "openai" and isinstance(node.get("content"), list) and node["content"]:
                    node["content"] = []
                    compatibility += 1
            if isinstance(node_type, str) and node_type in TOOL_TYPES:
                for key in ("call_id", "id"):
                    value = node.get(key)
                    if isinstance(value, str) and value.startswith("tool_"):
                        node[key] = "fc_" + value[5:]
                        compatibility += 1
            pending.extend(node.values())
    return route, compatibility


@dataclass
class RewriteStats:
    lines: int = 0
    changed_lines: int = 0
    route_changes: int = 0
    compatibility_changes: int = 0


def rewrite(path: Path, provider: str, model: str, effort: str) -> RewriteStats:
    header(path)
    before = path.stat()
    stats = RewriteStats()
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with path.open("rb") as source, os.fdopen(fd, "wb") as output:
            for number, raw in enumerate(source, 1):
                try:
                    record = json.loads(raw)
                    if not isinstance(record, dict):
                        raise ValueError("记录不是 JSON 对象")
                    route, compatibility = update_record(record, provider, model, effort)
                except (ValueError, UnicodeError, RecursionError) as exc:
                    raise ValueError(f"会话文件第 {number} 行不是有效记录：{path}") from exc
                stats.lines += 1
                stats.route_changes += route
                stats.compatibility_changes += compatibility
                if route or compatibility:
                    newline = b"\r\n" if raw.endswith(b"\r\n") else b"\n" if raw.endswith(b"\n") else b""
                    output.write(json.dumps(record, ensure_ascii=False, separators=(",", ":"),
                                            allow_nan=False).encode("utf-8") + newline)
                    stats.changed_lines += 1
                else:
                    output.write(raw)
            output.flush()
            os.fsync(output.fileno())
        if stats.changed_lines:
            current = path.stat()
            if (current.st_mtime_ns, current.st_size) != (before.st_mtime_ns, before.st_size):
                raise RuntimeError("会话文件被其它程序修改，已取消：" + str(path))
            os.replace(temporary, path)
            os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
        return stats
    finally:
        Path(temporary).unlink(missing_ok=True)


def connect(path: Path, readonly=False):
    return sqlite3.connect(path.resolve().as_uri() + ("?mode=ro" if readonly else "?mode=rw"),
                           uri=True, timeout=5)


def tables(connection) -> set[str]:
    return {r[0] for r in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def integrity(connection):
    if connection.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
        raise RuntimeError("SQLite 完整性检查失败。")


def find_database(home: Path, pattern: str, required: set[str]) -> Path | None:
    candidates = [p for directory in (home, home / "sqlite") for p in directory.glob(pattern) if p.is_file()]
    for path in sorted(candidates, key=lambda p: p.stat().st_mtime_ns, reverse=True):
        try:
            with closing(connect(path, readonly=True)) as connection:
                if required <= tables(connection):
                    return path
        except sqlite3.Error:
            continue
    return None


def backup_database(path: Path, backup: Path):
    backup.parent.mkdir(parents=True, exist_ok=True)
    with closing(connect(path, readonly=True)) as source, closing(sqlite3.connect(backup)) as target:
        integrity(source)
        source.backup(target)
        integrity(target)


def restore_database(backup: Path, path: Path):
    with closing(connect(backup, readonly=True)) as source, closing(connect(path)) as target:
        integrity(source)
        source.backup(target)
        integrity(target)


def find_ordinal_offset(path: Path, ordinal: int) -> int:
    offset = 0
    with path.open("rb") as stream:
        for raw in stream:
            if json.loads(raw).get("ordinal") == ordinal:
                return offset
            offset += len(raw)
    raise ValueError(f"无法在源会话找到 ordinal={ordinal}：{path}")


def set_history_offset(path: Path, offset: int):
    before = path.stat()
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with path.open("rb") as source, os.fdopen(fd, "wb") as output:
            raw = source.readline()
            record = json.loads(raw)
            record["payload"]["history_base"]["end_byte_offset"] = offset
            newline = b"\r\n" if raw.endswith(b"\r\n") else b"\n" if raw.endswith(b"\n") else b""
            output.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + newline)
            shutil.copyfileobj(source, output, 1024 * 1024)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
    finally:
        Path(temporary).unlink(missing_ok=True)


def repair_forks(paths: list[Path]) -> int:
    headers = {p: header(p) for p in paths}
    by_id = {}
    for path, meta in headers.items():
        by_id.setdefault(meta.get("id", meta.get("session_id")), []).append(path)
    visiting, finished = set(), set()
    changed = 0

    def visit(path):
        nonlocal changed
        if path in finished:
            return
        if path in visiting:
            raise ValueError("分叉会话存在循环依赖：" + str(path))
        visiting.add(path)
        base = headers[path].get("history_base")
        if isinstance(base, dict) and "end_byte_offset" in base and "end_ordinal_exclusive" in base:
            parents = sorted((p for p in by_id.get(base.get("thread_id"), []) if p != path), reverse=True)
            if not parents:
                raise ValueError("分叉会话找不到源会话：" + str(base.get("thread_id")))
            offset = None
            for parent in parents:
                visit(parent)
                try:
                    offset = find_ordinal_offset(parent, base["end_ordinal_exclusive"])
                    break
                except ValueError:
                    continue
            if offset is None:
                raise ValueError("无法重算分叉会话字节位置：" + str(path))
            if offset != base["end_byte_offset"]:
                set_history_offset(path, offset)
                changed += 1
        visiting.remove(path)
        finished.add(path)

    for path in paths:
        visit(path)
    return changed


@dataclass
class Migration:
    root: Path
    databases: list[tuple[Path, Path]] = field(default_factory=list)
    rollouts: list[tuple[Path, Path]] = field(default_factory=list)
    skipped: list[dict] = field(default_factory=list)
    database_rows: int = 0
    rollout_count: int = 0
    projection_rows: int = 0
    route_changes: int = 0
    compatibility_changes: int = 0
    forks_remapped: int = 0
    timings: list[dict] = field(default_factory=list)

    def restore(self):
        errors = []
        for path, backup in self.databases:
            try:
                restore_database(backup, path)
            except (OSError, sqlite3.Error, RuntimeError) as exc:
                errors.append(f"{path}: {exc}")
        for path, backup in self.rollouts:
            try:
                shutil.copy2(backup, path)
            except OSError as exc:
                errors.append(f"{path}: {exc}")
        if errors:
            raise RuntimeError("会话恢复失败，备份位于 " + str(self.root) + "\n" + "\n".join(errors))


def migrate(home: Path, provider: str, model: str, effort: str, backup_root: Path,
            progress=lambda percent, message: None) -> Migration:
    if not all(re.fullmatch(pattern, value) for pattern, value in (
        (r"[A-Za-z0-9_.-]+", provider), (r"[A-Za-z0-9_./:-]+", model), (r"[A-Za-z0-9_.-]+", effort))):
        raise ValueError("目标 provider、模型或推理强度格式无效。")
    home = home.resolve()
    result = Migration(backup_root)
    paths = rollout_files(home)
    database = find_database(home, "state_*.sqlite", {"threads"})
    projection = find_database(home, "thread_history_*.sqlite", set(PROJECTION_TABLES[:3]))
    if not database and not paths:
        return result
    if not database:
        raise ValueError("发现会话文件，但没有找到包含 threads 表的 Codex state 数据库。未做修改。")
    progress(2, "正在备份会话和数据库…")
    phase_started = time.perf_counter()
    backup_root.mkdir(parents=True, exist_ok=True)
    for path in paths:
        if not path.resolve().is_relative_to(home):
            raise ValueError("会话路径不在 Codex 根目录内：" + str(path))
        try:
            header(path)
        except ValueError as exc:
            result.skipped.append({"path": str(path), "reason": str(exc)})
            continue
        backup = backup_root / "rollouts" / path.relative_to(home)
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, backup)
        result.rollouts.append((path, backup))
    for kind, path in (("state", database), ("projection", projection)):
        if path:
            backup = backup_root / kind / path.name
            backup_database(path, backup)
            result.databases.append((path, backup))
    result.timings.append({"phase": "backup", "seconds": time.perf_counter() - phase_started,
                           "rollouts": len(result.rollouts)})
    try:
        phase_started = time.perf_counter()
        with closing(connect(database)) as db, db:
            columns = {r[1] for r in db.execute("PRAGMA table_info(threads)")}
            if not {"id", "rollout_path", "model_provider", "model", "reasoning_effort"} <= columns:
                raise ValueError("Codex threads 表缺少必要路由列，已取消迁移。")
            result.database_rows = db.execute("SELECT count(*) FROM threads").fetchone()[0]
            db.execute("UPDATE threads SET model_provider=?, model=?, reasoning_effort=?", (provider, model, effort))
        result.timings.append({"phase": "sqlite_routes", "seconds": time.perf_counter() - phase_started,
                               "rows": result.database_rows})
        good = []
        for index, (path, _) in enumerate(result.rollouts):
            started = time.perf_counter()
            try:
                stats = rewrite(path, provider, model, effort)
            except ValueError as exc:
                result.skipped.append({"path": str(path), "reason": "改写失败：" + str(exc)})
                continue
            good.append(path)
            result.rollout_count += 1
            result.route_changes += stats.route_changes
            result.compatibility_changes += stats.compatibility_changes
            result.timings.append({"phase": "rewrite", "path": str(path), "seconds": time.perf_counter() - started,
                                   "bytes": path.stat().st_size, **vars(stats)})
            progress(16 + int(64 * (index + 1) / max(1, len(result.rollouts))),
                     f"已处理会话 {index + 1}/{len(result.rollouts)}")
        if result.rollouts and not good:
            raise ValueError("所有会话文件都无法改写，已取消并恢复备份。")
        if result.skipped:
            backup = result.databases[0][1]
            with closing(connect(backup, True)) as original, closing(connect(database)) as db, db:
                restored = set()
                rows = original.execute("SELECT id, rollout_path, model_provider, model, reasoning_effort FROM threads").fetchall()
                for item in result.skipped:
                    path = Path(item["path"])
                    candidates = {str(path).replace("\\", "/").casefold(), path.relative_to(home).as_posix().casefold()}
                    try:
                        meta = header(path)
                        session_id = meta.get("id", meta.get("session_id"))
                    except ValueError:
                        session_id = None
                    for row in rows:
                        if row[0] not in restored and (row[0] == session_id or str(row[1]).replace("\\", "/").casefold() in candidates):
                            db.execute("UPDATE threads SET model_provider=?, model=?, reasoning_effort=? WHERE id=?", (*row[2:], row[0]))
                            restored.add(row[0])
                result.database_rows -= len(restored)
        phase_started = time.perf_counter()
        result.forks_remapped = repair_forks(good)
        result.timings.append({"phase": "fork_offsets", "seconds": time.perf_counter() - phase_started,
                               "remapped": result.forks_remapped})
        progress(84, "已修复分叉会话字节偏移…")
        if projection:
            phase_started = time.perf_counter()
            with closing(connect(projection)) as db, db:
                for table in PROJECTION_TABLES:
                    if table in tables(db):
                        result.projection_rows += db.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0]
                        db.execute(f'DELETE FROM "{table}"')
                integrity(db)
            result.timings.append({"phase": "projection", "seconds": time.perf_counter() - phase_started,
                                   "rows": result.projection_rows})
        manifest = {**vars(result), "targetProvider": provider, "targetModel": model,
                    "targetReasoningEffort": effort}
        write_json(backup_root / "manifest.json", json.loads(json.dumps(manifest, default=str)))
        progress(94, "历史会话迁移完成")
        return result
    except Exception as failure:
        try:
            result.restore()
        except Exception as recovery:
            raise RuntimeError(f"{failure}\n{recovery}") from failure
        raise
