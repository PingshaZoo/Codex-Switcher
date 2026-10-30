"""Conservative TOML editing: preserve unrelated text and validate before writing."""

from __future__ import annotations

import json
from pathlib import Path
import re
import tomllib

from .storage import read_json


MANAGED = frozenset({"model", "model_provider", "model_catalog_json", "model_context_window",
    "model_auto_compact_token_limit", "model_reasoning_effort", "model_reasoning_summary",
    "model_verbosity", "model_supports_reasoning_summaries", "disable_response_storage",
    "forced_login_method", "openai_base_url", "review_model", "service_tier", "web_search"})
ROOT_KEY = re.compile(r'''^\s*(?:"([\w-]+)"|'([\w-]+)'|([\w-]+))\s*=''')
BLOCKS = {
    label: re.compile(r"(?ms)^# " + label + r"-BEGIN\n.*?^# " + label + r"-END\n?")
    for label in ("CODEX-PROFILES", "CODEX-SWITCHER")
}


def quote(value: str) -> str:
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("配置值不能包含换行或控制字符。")
    return json.dumps(value, ensure_ascii=False)


def normalize(text: str) -> str:
    return text.removeprefix("\ufeff").replace("\r\n", "\n")


def parse(text: str) -> dict:
    return tomllib.loads(normalize(text))


def strip_blocks(text: str, *labels: str) -> str:
    text = normalize(text)
    for label in labels or BLOCKS:
        begin, end = f"# {label}-BEGIN", f"# {label}-END"
        if text.count(begin) != text.count(end) or text.count(begin) > 1:
            raise ValueError("工具托管标记不完整或重复，未修改配置。")
        text = BLOCKS[label].sub("", text)
        if begin in text or end in text:
            raise ValueError("无法安全识别工具托管配置区，未修改配置。")
    return text


def split_config(text: str) -> tuple[list[str], str]:
    text = normalize(text)
    parse(text)
    if '"""' in text or "'''" in text:
        raise ValueError("此配置含 TOML 多行字符串，工具无法安全局部编辑，未做修改。")
    roots, rest = [], []
    at_root = True
    for line in text.splitlines(keepends=True):
        # Only syntactically valid table headers end the root section. Array values
        # on continuation lines must not be mistaken for headers.
        if re.match(r"^\s*\[", line):
            try:
                header = tomllib.loads(line)
                if header:
                    at_root = False
            except tomllib.TOMLDecodeError:
                pass
        match = ROOT_KEY.match(line) if at_root else None
        key = next((part for part in match.groups() if part), "") if match else ""
        if key in MANAGED:
            try:
                tomllib.loads(line)
            except tomllib.TOMLDecodeError as exc:
                raise ValueError("托管根键使用了多行值，无法安全局部编辑：" + key) from exc
            roots.append(line.rstrip("\n"))
        else:
            rest.append(line)
    return roots, "".join(rest)


def root_values(roots: list[str]) -> dict:
    return tomllib.loads("\n".join(roots))


def make_config(original: str, roots: list[str], definitions: str) -> str:
    _, rest = split_config(original)
    result = (("\n".join(roots) + "\n") if roots else "") + rest.rstrip() + "\n" + definitions
    parse(result)
    return result


def _walk_key(value, key):
    if isinstance(value, dict):
        for name, child in value.items():
            if name == key:
                yield child
            yield from _walk_key(child, key)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_key(child, key)


def official_candidates(home: Path) -> list[str]:
    result = []
    try:
        state = read_json(home / ".codex-global-state.json", {})
    except (ValueError, OSError):
        state = {}
    for slug in _walk_key(state, "default_model_slug"):
        if isinstance(slug, str):
            result.append(slug.removesuffix("-wm"))
    for slugs in _walk_key(state, "eligible_codex_model_slugs"):
        if isinstance(slugs, list):
            result.extend(s for s in slugs if isinstance(s, str))
    try:
        models = read_json(home / "models_cache.json", {}).get("models", [])
        def priority(model):
            try:
                return int(model.get("priority", 999))
            except (ValueError, TypeError):
                return 999
        result.extend(m["slug"] for m in sorted(models, key=priority)
                      if m.get("visibility") != "hide" and isinstance(m.get("slug"), str))
    except (ValueError, OSError, AttributeError, TypeError):
        pass
    # Local caches may also contain third-party entries; do not pick those.
    return list(dict.fromkeys(s for s in result if re.fullmatch(r"gpt-[A-Za-z0-9_./:-]+", s)))


def resolve_official(home: Path, roots: list[str], saved: str = "", explicit: str = "") -> str:
    choices = [root_values(roots).get("model", ""), saved, explicit, *official_candidates(home)]
    for model in choices:
        if isinstance(model, str) and re.fullmatch(r"gpt-[A-Za-z0-9_./:-]+", model):
            return model
    return ""
