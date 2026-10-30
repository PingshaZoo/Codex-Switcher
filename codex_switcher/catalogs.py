"""Provider-supplied model capability catalogs; never infer another vendor's abilities."""

from copy import deepcopy
from pathlib import Path
import re

from .storage import read_json


def split_models(value: str | list[str]) -> list[str]:
    parts = re.split(r"[,;\s]+", value) if isinstance(value, str) else value
    if not isinstance(parts, list) or any(not isinstance(v, str) for v in parts):
        raise ValueError("模型列表必须是字符串数组。")
    return list(dict.fromkeys(p.strip() for p in parts if p.strip()))


def read_catalog(path: Path, models=()) -> dict:
    catalog = read_json(path)
    if not isinstance(catalog, dict) or not isinstance(catalog.get("models"), list) or not catalog["models"]:
        raise ValueError("模型目录没有 models 数组或内容为空：" + str(path))
    entries = {}
    for item in catalog["models"]:
        if not isinstance(item, dict) or not isinstance(item.get("slug"), str):
            raise ValueError("模型目录条目缺少有效 slug：" + str(path))
        if item["slug"] in entries:
            raise ValueError("模型目录存在重复 slug：" + item["slug"])
        entries[item["slug"]] = item
    for slug in models:
        if slug not in entries:
            raise ValueError("模型目录缺少模型：" + slug)
        if "base_instructions" not in entries[slug]:
            raise ValueError("模型目录缺少 base_instructions：" + slug)
    return catalog


def extend_legacy_deepseek(catalog: dict, models: list[str]) -> dict:
    """Only legacy DeepSeek import uses its own existing metadata as a template."""
    result = deepcopy(catalog)
    entries = result["models"]
    template = next((e for e in entries if "base_instructions" in e), None)
    if template is None:
        raise ValueError("旧 DeepSeek 目录缺少完整能力模板，请指定有效目录。")
    existing = {e["slug"] for e in entries}
    priority = max((e.get("priority", 0) for e in entries if isinstance(e.get("priority", 0), int)), default=0)
    for slug in models:
        if slug not in existing:
            priority += 1
            item = deepcopy(template)
            item.update(slug=slug, display_name=slug, priority=priority)
            entries.append(item)
            existing.add(slug)
    return result
