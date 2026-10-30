"""Provider profiles and transactional switching. GUI and CLI share these operations."""

from __future__ import annotations

from copy import deepcopy
from datetime import datetime
import json
from pathlib import Path
import re
import sys
import time
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler

from . import credentials
from .catalogs import read_catalog, split_models
from .config import parse, strip_blocks, split_config, root_values, quote, make_config, resolve_official
from .migration import migrate
from .platform import assert_closed
from .storage import (FileTransaction, SwitchLock, atomic_write, read_text, read_json,
                      write_json, fingerprint, operation_id, diagnostic_logger, close_logger)


def tool_dir(config: Path) -> Path:
    return config.resolve().parent / "codex-switcher"


def validate_id(value: str):
    if not isinstance(value, str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", value) or value in {"openai", "codex_switcher_deepseek"}:
        raise ValueError("供应商 ID 需以小写字母开头，仅含小写字母、数字、下划线、短横线；openai 为保留名称。")


def validate_url(value: str) -> str:
    if not isinstance(value, str) or any(ord(c) < 33 or ord(c) == 127 for c in value):
        raise ValueError("接口地址不能包含空白或控制字符。")
    url = urlsplit(value)
    if url.scheme != "https" or not url.hostname or url.username is not None or url.password is not None or url.query or url.fragment:
        raise ValueError("接口地址必须是 HTTPS 基础地址，不含密码、查询参数或片段。")
    try:
        url.port
    except ValueError as exc:
        raise ValueError("接口地址端口无效。") from exc
    return value.rstrip("/")


def new_profile(identifier: str, name: str, base_url: str, models: str | list[str],
                key: str = "", catalog: str = "", previous: dict | None = None) -> dict:
    validate_id(identifier)
    if not isinstance(name, str) or not name.strip():
        raise ValueError("请填写供应商名称。")
    quote(name)
    base_url = validate_url(base_url)
    models = split_models(models)
    if not models or any(not re.fullmatch(r"[A-Za-z0-9_./:-]+", slug) for slug in models):
        raise ValueError("请填写有效模型列表，第一个模型为默认模型。")
    if catalog:
        catalog = str(Path(catalog).expanduser().resolve())
        read_catalog(Path(catalog), models)
    credential = credentials.encrypt(key) if key else (previous or {}).get("credential", "")
    if not isinstance(credential, str) or not credential:
        raise ValueError("首次添加供应商请填写 API Key。")
    try:
        bytes.fromhex(credential)
    except ValueError as exc:
        raise ValueError("保存的凭证格式无效，请重新填写 API Key。") from exc
    return {"id": identifier, "name": name.strip(), "baseUrl": base_url, "models": models,
            "catalog": catalog, "credential": credential, "succeeded": False}


def set_profile(store: dict, profile: dict):
    profiles = store["profiles"]
    for index, item in enumerate(profiles):
        if item["id"] == profile["id"]:
            profiles[index] = profile
            return
    profiles.append(profile)


def load_store(config: Path) -> dict:
    config = config.resolve()
    directory = tool_dir(config)
    path = directory / "providers.json"
    revision = fingerprint(path)
    if path.is_file():
        store = read_json(path)
        if not isinstance(store, dict) or store.get("version") != 1 or not isinstance(store.get("profiles"), list):
            raise ValueError("不支持的供应商档案格式或版本。")
        identifiers = set()
        for profile in store["profiles"]:
            if not isinstance(profile, dict):
                raise ValueError("供应商档案条目无效。")
            validate_id(profile.get("id"))
            if profile["id"] in identifiers:
                raise ValueError("供应商档案中存在重复 ID。")
            identifiers.add(profile["id"])
    else:
        state = read_json(directory / "state.json", {}) or {}
        text = strip_blocks(read_text(config))
        roots, _ = split_config(text)
        provider = root_values(roots).get("model_provider", "openai")
        captured = isinstance(state.get("officialRoot"), list) or provider == "openai"
        store = {"version": 1, "selected": "deepseek" if state.get("mode") == "deepseek" else "openai",
                 "officialRoot": state.get("officialRoot", roots if provider == "openai" else []),
                 "officialCaptured": captured, "officialModel": state.get("officialModel", ""), "profiles": []}
        key = directory / "deepseek.key"
        if state.get("apiBase") and key.is_file():
            catalog = state.get("catalog", "")
            if not catalog or not Path(catalog).is_file():
                catalog = str(directory / "deepseek-models.json") if (directory / "deepseek-models.json").is_file() else ""
            models = split_models(state.get("model", ""))
            if catalog:
                models = list(dict.fromkeys(models + [m["slug"] for m in read_catalog(Path(catalog))["models"]]))
            store["profiles"].append({"id": "deepseek", "name": "DeepSeek", "baseUrl": state["apiBase"],
                "models": models, "catalog": catalog, "credential": read_text(key).strip(), "succeeded": True})
    store["_revision"] = revision
    return store


def _public_store(store: dict) -> dict:
    return {key: value for key, value in store.items() if not key.startswith("_")}


def _check_revision(directory: Path, store: dict):
    if "_revision" not in store or fingerprint(directory / "providers.json") != store["_revision"]:
        raise RuntimeError("供应商档案已被其它操作修改，请重新加载后重试。")


def save_store(config: Path, store: dict):
    directory = tool_dir(config)
    with SwitchLock(directory):
        _check_revision(directory, store)
        transaction = FileTransaction(directory / "profile-backups" / operation_id(), [directory / "providers.json"])
        try:
            write_json(directory / "providers.json", _public_store(store))
        except Exception:
            transaction.restore()
            raise
    store["_revision"] = fingerprint(directory / "providers.json")


def _cached_profile(profile: dict, directory: Path) -> dict:
    result = deepcopy(profile)
    if result.get("catalog") and not Path(result["catalog"]).is_file():
        cached = directory / "catalogs" / (result["id"] + ".json")
        if cached.is_file():
            result["catalog"] = str(cached)
    validated = new_profile(result["id"], result["name"], result["baseUrl"], result["models"],
                            catalog=result.get("catalog", ""), previous=result)
    validated["succeeded"] = bool(result.get("succeeded", False))
    return validated


def definitions(directory: Path, profiles: list[dict], alias=False) -> str:
    lines = ["# CODEX-PROFILES-BEGIN"]
    for profile in profiles:
        ids = [profile["id"]]
        if alias and profile["id"] == "deepseek":
            ids.append("codex_switcher_deepseek")
        for identifier in ids:
            args = ["-I", "-X", "utf8", str(directory / "profile-credential.py"), "--emit-key",
                    str(directory / "keys" / (profile["id"] + ".key"))]
            lines.extend([f"[model_providers.{identifier}]", "name = " + quote(profile["name"]),
                "base_url = " + quote(profile["baseUrl"]), 'wire_api = "responses"',
                f"[model_providers.{identifier}.auth]", "command = " + quote(sys.executable),
                "args = [" + ", ".join(quote(arg) for arg in args) + "]", "timeout_ms = 10000", "refresh_interval_ms = 0"])
    return "\n".join(lines + ["# CODEX-PROFILES-END", ""])


def switch(config: Path, store: dict, identifier: str, migrate_chats=False, official_model="",
           progress=lambda percent, message: None) -> dict:
    config = config.resolve()
    home, directory = config.parent, tool_dir(config)
    logger = diagnostic_logger(directory)
    started_at = time.perf_counter()
    transaction, migration = None, None
    started = False
    expected_files = {}
    lock = SwitchLock(directory)
    try:
        lock.__enter__()
        assert_closed()
        _check_revision(directory, store)
        config_revision = fingerprint(config)
        expected_files = {config: config_revision, directory / "providers.json": store["_revision"]}
        original = read_text(config)
        original_values = parse(original)
        if "profile" in original_values:
            raise ValueError("检测到 profile 选择器，请先移除或迁移它。")
        legacy_alias = "# CODEX-SWITCHER-BEGIN" in original or "codex_switcher_deepseek" in original_values.get("model_providers", {})
        clean = strip_blocks(original)
        roots, _ = split_config(clean)
        current = root_values(roots)
        draft = deepcopy(store)
        if current.get("model_provider", "openai") == "openai":
            draft.update(officialRoot=roots, officialCaptured=True,
                         officialModel=resolve_official(home, roots, draft.get("officialModel", "")))
        # Validate every stored profile because definitions are deployed together.
        draft["profiles"] = [_cached_profile(p, directory) for p in draft["profiles"]]
        existing_providers = parse(clean).get("model_providers", {})
        for p in draft["profiles"]:
            if p["id"] in existing_providers or (legacy_alias and p["id"] == "deepseek" and "codex_switcher_deepseek" in existing_providers):
                raise ValueError("配置已有同名供应商，避免覆盖请换一个 ID：" + p["id"])
        target = None
        if identifier == "openai":
            if not draft.get("officialCaptured"):
                raise ValueError("没有保存的官方配置。请先恢复官方配置后再导入。")
            roots = draft.get("officialRoot") or []
            model = resolve_official(home, roots, draft.get("officialModel", ""), official_model)
            if migrate_chats and not model:
                raise ValueError("迁移历史会话需明确的官方模型；请关闭历史迁移或填写 gpt-* 模型名。")
            effort = root_values(roots).get("model_reasoning_effort", "medium")
        else:
            target = next((p for p in draft["profiles"] if p["id"] == identifier), None)
            if target is None:
                raise ValueError("找不到所选供应商。")
            model, effort = target["models"][0], "high"
            roots = ["model_provider = " + quote(identifier), "model = " + quote(model),
                     'model_reasoning_effort = "high"', 'web_search = "disabled"']
            if target["catalog"]:
                catalog = read_catalog(Path(target["catalog"]), target["models"])
                metadata = next(m for m in catalog["models"] if m["slug"] == model)
                roots.append("model_catalog_json = " + quote(str(directory / "catalogs" / (identifier + ".json"))))
                if metadata.get("supports_reasoning_summaries") is True:
                    roots.extend(['model_supports_reasoning_summaries = true', 'model_reasoning_summary = "none"'])
                window = metadata.get("context_window")
                if isinstance(window, int) and not isinstance(window, bool) and window > 0:
                    roots.append("model_context_window = " + str(window))
        updated = make_config(clean, roots, definitions(directory, draft["profiles"], legacy_alias))
        backup_root = directory / "profile-backups" / operation_id()
        paths = [config, directory / "providers.json", directory / "profile-credential.py"]
        for p in draft["profiles"]:
            paths.append(directory / "keys" / (p["id"] + ".key"))
            if p["catalog"]:
                paths.append(directory / "catalogs" / (p["id"] + ".json"))
        transaction = FileTransaction(backup_root, paths)
        if fingerprint(config) != config_revision:
            raise RuntimeError("配置已被其它程序修改，请重新加载后重试。")
        assert_closed()
        _check_revision(directory, store)
        # From here onward every mutation is covered by this transaction.
        started = True
        progress(5, "正在部署凭证助手和模型目录…")
        atomic_write(directory / "profile-credential.py", Path(credentials.__file__).read_bytes())
        for p in draft["profiles"]:
            atomic_write(directory / "keys" / (p["id"] + ".key"), p["credential"])
            if p["catalog"]:
                write_json(directory / "catalogs" / (p["id"] + ".json"), read_catalog(Path(p["catalog"]), p["models"]))
        if migrate_chats:
            migration = migrate(home, identifier, model, effort, backup_root / "chats", progress)
        assert_closed()
        if fingerprint(config) != config_revision:
            # Do not overwrite an external edit on the failure path.
            transaction.files = [e for e in transaction.files if Path(e["path"]) != config]
            raise RuntimeError("配置在切换期间被其它程序修改，已取消；外部修改已保留。")
        if fingerprint(directory / "providers.json") != store["_revision"]:
            transaction.files = [e for e in transaction.files if Path(e["path"]) != directory / "providers.json"]
            raise RuntimeError("供应商档案在切换期间被其它程序修改，已取消；外部修改已保留。")
        draft["selected"] = identifier
        if identifier == "openai" and model:
            draft["officialModel"] = model
        if target:
            target["succeeded"] = True
        write_json(directory / "providers.json", _public_store(draft))
        expected_files[directory / "providers.json"] = fingerprint(directory / "providers.json")
        atomic_write(config, updated)
        expected_files[config] = fingerprint(config)
        seconds = time.perf_counter() - started_at
        report = {"provider": identifier, "model": model, "backup": str(backup_root),
                  "migrated": migrate_chats, "seconds": round(seconds, 3),
                  "skipped": migration.skipped if migration else [],
                  "rollouts": migration.rollout_count if migration else 0,
                  "databaseRows": migration.database_rows if migration else 0,
                  "forksRemapped": migration.forks_remapped if migration else 0}
        logger.info("Switch succeeded: provider=%s model=%s backup=%s seconds=%.3f", identifier, model, backup_root, seconds)
        _append_log(directory / "switch.log", json.dumps(report, ensure_ascii=False))
        if migration:
            for phase in migration.timings:
                _append_log(directory / "switch-timing.log", json.dumps(phase, ensure_ascii=False))
        _append_log(directory / "switch-timing.log", json.dumps(report, ensure_ascii=False))
        progress(100, "切换完成，请重启 Codex。")
        return report
    except Exception as failure:
        logger.exception("Switch failed")
        recovery_errors = []
        if migration:
            try:
                migration.restore()
            except Exception as exc:
                recovery_errors.append(str(exc))
        if transaction and started:
            try:
                for path, expected in expected_files.items():
                    if fingerprint(path) != expected:
                        transaction.files = [e for e in transaction.files if Path(e["path"]) != path]
                        logger.warning("External edit preserved during rollback: %s", path)
                transaction.restore()
            except Exception as exc:
                recovery_errors.append(str(exc))
        if recovery_errors:
            logger.error("Rollback incomplete: %s", "\n".join(recovery_errors))
            raise RuntimeError(f"{failure}\n" + "\n".join(recovery_errors)) from failure
        raise
    finally:
        lock.__exit__()
        close_logger(logger)


def _append_log(path: Path, text: str):
    try:
        with path.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(datetime.now().isoformat(timespec="seconds") + " " + text + "\n")
    except OSError:
        pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Authorization must never follow a provider's cross-host redirect.
        return None


def fetch_models(base_url: str, secret: str, timeout=20) -> list[str]:
    base_url = validate_url(base_url)
    if not secret or any(c.isspace() for c in secret):
        raise ValueError("请填写有效 API Key。")
    request = Request(base_url + "/models", headers={"Authorization": "Bearer " + secret, "Accept": "application/json"})
    try:
        with build_opener(NoRedirect()).open(request, timeout=timeout) as response:
            body = response.read(4 * 1024 * 1024 + 1)
            if len(body) > 4 * 1024 * 1024:
                raise ValueError("模型列表过大。")
            value = json.loads(body)
        data = value.get("data") if isinstance(value, dict) else None
        if not isinstance(data, list):
            raise ValueError("接口未返回 data[].id。")
        models = split_models([m["id"] for m in data if isinstance(m, dict) and isinstance(m.get("id"), str)])
        if not models:
            raise ValueError("接口未返回模型。")
        return models
    except Exception:
        # Do not expose response bodies or authorization headers through exceptions.
        raise RuntimeError("获取模型失败，请检查地址、密钥和 /models 支持情况，或手动填写模型。") from None
