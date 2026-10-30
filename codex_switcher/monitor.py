"""Read-only session diagnostics. Response ID shapes are clues, not verified origins."""

from __future__ import annotations

from collections import Counter
from datetime import datetime
import json
from pathlib import Path
import re

from .config import parse
from .migration import rollout_files, header
from .storage import read_text


def fingerprint_kind(value: str) -> str:
    if re.fullmatch(r"resp_[0-9a-fA-F]{16,}", value):
        return "OpenAI 格式（来源未验证）"
    if re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value):
        return "UUID 格式（来源未验证）"
    return "其他格式"


def records(path: Path, tail_bytes=0):
    with path.open("rb") as stream:
        if tail_bytes and path.stat().st_size > tail_bytes:
            stream.seek(-tail_bytes, 2)
            stream.readline()  # discard the partial first line, including a possible split UTF-8 character
        for raw in stream:
            try:
                value = json.loads(raw)
                if isinstance(value, dict):
                    yield value
            except (ValueError, UnicodeError):
                continue


def response_ids(path: Path, tail_bytes=0, max_count=0):
    entries = []
    for record in records(path, tail_bytes):
        payload = record.get("payload")
        value = payload.get("response_id") if isinstance(payload, dict) else None
        if isinstance(value, str) and value:
            entries.append({"timestamp": record.get("timestamp", ""), "id": value, "kind": fingerprint_kind(value)})
    return entries[-max_count:] if max_count else entries


def runtime(path: Path, max_scan_bytes=8 * 1024**2):
    result = {"model": "", "provider": "", "effort": "", "timestamp": ""}
    # Keep only small runtime records, rather than all tool output in the tail window.
    for record in records(path, max_scan_bytes):
        payload = record.get("payload")
        if not isinstance(payload, dict):
            continue
        if record.get("type") == "turn_context":
            if payload.get("model"):
                result["model"] = payload["model"]
            if payload.get("effort"):
                result["effort"] = payload["effort"]
            result["timestamp"] = record.get("timestamp", "")
        elif record.get("type") == "event_msg" and payload.get("type") == "thread_settings_applied":
            settings = payload.get("thread_settings")
            if isinstance(settings, dict):
                for source, target in (("model", "model"), ("model_provider_id", "provider"), ("reasoning_effort", "effort")):
                    if settings.get(source):
                        result[target] = settings[source]
                result["timestamp"] = record.get("timestamp", "")
    return result


def snapshot(home: Path, recent=6, tail_bytes=262144, full=False, config_path: Path | None = None):
    home = home.resolve()
    config_path = config_path or home / "config.toml"
    result = {"config": str(config_path), "provider": "openai", "model": "（由官方登录提供）", "baseUrl": "（由官方登录提供）",
              "threadId": "", "threadFile": "", "threadModel": "", "threadProvider": "", "threadEffort": "",
              "originModel": "", "lastId": "", "lastKind": "", "entries": [], "timeline": [], "lines": [],
              "conclusion": "尚无响应记录", "headline": "未找到会话文件"}
    lines = result["lines"]
    try:
        config = parse(read_text(config_path))
        provider = config.get("model_provider", "openai")
        definition = config.get("model_providers", {}).get(provider, {})
        result.update(provider=provider, model=config.get("model", result["model"]),
                      baseUrl=definition.get("base_url", result["baseUrl"]))
        auth = "命令认证" if "auth" in definition else "ChatGPT 官方登录" if provider == "openai" else "供应商配置"
    except (OSError, ValueError) as exc:
        auth = "无法读取配置"
        lines.append("配置读取失败：" + type(exc).__name__)
    lines.extend(["配置文件：" + str(config_path), "新对话默认模型：" + str(result["model"]),
                  "新对话默认来源：" + str(result["provider"]), "当前配置接口：" + str(result["baseUrl"]),
                  "认证方式：" + auth, ""])
    paths = rollout_files(home)
    if not paths:
        lines.append("没有找到 rollout-*.jsonl。先产生一次对话，再刷新。")
        return result
    path = max(paths, key=lambda p: p.stat().st_mtime_ns)
    try:
        meta = header(path)
    except ValueError as exc:
        lines.append("最近会话无法读取：" + str(exc))
        meta = {}
    current = runtime(path)
    instructions = meta.get("base_instructions", {})
    provenance = instructions.get("provenance", {}) if isinstance(instructions, dict) else {}
    result.update(threadId=meta.get("id", meta.get("session_id", "?")), threadFile=str(path),
                  threadModel=current["model"], threadProvider=current["provider"] or meta.get("model_provider", ""),
                  threadEffort=current["effort"], originModel=provenance.get("model", "（未记录）"))
    lines.extend(["会话文件：" + str(path), "会话 ID：" + str(result["threadId"]),
                  "本对话运行时模型：" + str(result["threadModel"] or "（未记录）"),
                  "本对话供应商：" + str(result["threadProvider"] or "（未记录）"),
                  "本对话推理强度：" + str(result["threadEffort"] or "（未记录）"),
                  "创建时模型：" + str(result["originModel"])])
    if current["model"] and current["model"] != result["model"]:
        lines.append("提示：本对话模型与新对话默认模型不同；config.toml 的设置只影响新建对话。")
    entries = response_ids(path, tail_bytes)
    result["entries"] = entries[-recent:]
    lines.extend(["", "最近响应 ID（格式不能单独证明后端身份）："])
    for entry in result["entries"]:
        lines.append(f"{entry['timestamp']}  {entry['id']}  {entry['kind']}")
    if entries:
        last = entries[-1]
        result.update(lastId=last["id"], lastKind=last["kind"],
                      headline="最近响应：" + last["kind"] + " / 会话供应商：" + str(result["threadProvider"]),
                      conclusion="会话记录的供应商：" + str(result["threadProvider"]) + "；响应格式不能验证实际网络去向")
        lines.append("尾部窗口统计：" + "，".join(f"{kind} × {count}" for kind, count in Counter(e["kind"] for e in entries).items()))
    else:
        result["headline"] = "尚无响应记录"
    if full:
        for entry in response_ids(path):
            runs = result["timeline"]
            if runs and runs[-1]["kind"] == entry["kind"]:
                runs[-1]["last"] = entry["timestamp"]
                runs[-1]["count"] += 1
            else:
                runs.append({"kind": entry["kind"], "first": entry["timestamp"], "last": entry["timestamp"], "count": 1})
        lines.extend(["", "完整时间线："])
        lines.extend(f"{r['first']} ~ {r['last']}  {r['kind']}  {r['count']} 次" for r in result["timeline"])
    lines.extend(["", result["conclusion"], "当前配置不能证明历史请求实际去向，可用代理连接目标域名及供应商用量记录交叉验证。"])
    return result


def scan_all(home: Path):
    rows = []
    for path in rollout_files(home):
        try:
            meta = header(path)
            entries = response_ids(path)
            rows.append({"file": str(path), "id": meta.get("id", meta.get("session_id", "?")),
                         "provider": meta.get("model_provider", ""), "responses": len(entries),
                         "lastKind": entries[-1]["kind"] if entries else "尚无响应记录"})
        except (OSError, ValueError) as exc:
            rows.append({"file": str(path), "problem": str(exc)})
    return rows


def append_watch_log(home: Path, value: dict):
    if not value.get("lastId"):
        return
    directory = home / "codex-switcher"
    directory.mkdir(parents=True, exist_ok=True)
    entry = {"timestamp": datetime.now().isoformat(timespec="seconds"),
             "provider": value["threadProvider"], "model": value["threadModel"],
             "threadId": value["threadId"], "responseId": value["lastId"], "kind": value["lastKind"],
             "source": "session record; network destination not verified"}
    with (directory / "provider-watch.log").open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(entry, ensure_ascii=False) + "\n")
