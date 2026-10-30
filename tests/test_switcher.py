"""Regression tests use temporary homes and dummy secrets, never the user's .codex."""

from contextlib import closing
from copy import deepcopy
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from codex_switcher import catalogs, config, credentials, migration, monitor, profiles, storage


def put(path, value):
    storage.atomic_write(path, json.dumps(value, ensure_ascii=False) if isinstance(value, (dict, list)) else value)


def powershell_env():
    # Python launched from PowerShell 7 inherits its module path; Windows PS 5.1
    # must rebuild its own path rather than load incompatible .NET assemblies.
    return {k: v for k, v in os.environ.items() if k.upper() != "PSMODULEPATH"}


def meta(identifier="one", provider="openai", **extra):
    return {"ordinal": 0, "type": "session_meta", "payload": {"id": identifier,
        "model_provider": provider, "base_instructions": {"text": "Keep me", "provenance": {"model": "gpt-origin"}}, **extra}}


def rollout(path, records, newline=b"\n", trailing=True):
    put(path, newline.join(json.dumps(r, ensure_ascii=False).encode("utf-8") if isinstance(r, dict) else r for r in records) + (newline if trailing else b""))


def database(path, rows=()):
    path.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(path)) as db, db:
        db.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, model_provider TEXT, model TEXT, reasoning_effort TEXT, title TEXT)")
        for identifier, rollout_path in rows:
            db.execute("INSERT INTO threads VALUES (?, ?, 'openai', 'gpt-old', 'medium', 'Visible title')", (identifier, str(rollout_path)))


class HomeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="switcher-python-test-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.path = self.home / "config.toml"
        self.original = 'model = "gpt-official"\nweb_search = "enabled"\nnotify = ["C:\\\\tools\\\\通知.exe"]\n\n[features]\njs_repl = false\n[mcp_servers.demo]\ncommand = "demo.exe"\n'
        put(self.path, self.original)
        put(self.home / "auth.json", '{"unchanged":"official login"}')
        self.guard = patch("codex_switcher.profiles.assert_closed")
        self.guard.start()
        self.addCleanup(self.guard.stop)

    def profile(self, identifier="vendor_a", model="model-a", key="dummy-secret-a", catalog="", previous=None):
        return profiles.new_profile(identifier, "测试 " + identifier, "https://example.invalid/v1", model, key, catalog, previous)

    def store(self, *items):
        store = profiles.load_store(self.path)
        for item in items:
            profiles.set_profile(store, item)
        return store

    def apply(self, identifier, store=None, **kwargs):
        return profiles.switch(self.path, store if store is not None else profiles.load_store(self.path), identifier, **kwargs)

    def values(self):
        return config.parse(storage.read_text(self.path))


class ConfigTests(HomeTest):
    def test_roundtrip_preserves_unmanaged_settings_and_auth(self):
        self.apply("vendor_a", self.store(self.profile()))
        self.assertEqual(self.values()["model_provider"], "vendor_a")
        self.apply("openai")
        self.assertEqual(config.split_config(config.strip_blocks(storage.read_text(self.path))), config.split_config(self.original))
        self.assertEqual(storage.read_text(self.home / "auth.json"), '{"unchanged":"official login"}')
        self.assertIn("vendor_a", self.values()["model_providers"])

    def test_empty_official_roots_need_no_model_when_not_migrating(self):
        put(self.path, 'notify = []\n[features]\njs_repl = false\n')
        self.apply("vendor_a", self.store(self.profile()))
        self.apply("openai")
        self.assertNotIn("model", self.values())
        self.assertNotIn("model_provider", self.values())

    def test_quoted_root_keys_and_repeated_switches(self):
        put(self.path, '"model" = "gpt-official"\nnotify = []\n')
        self.apply("vendor_a", self.store(self.profile()))
        for _ in range(3):
            self.apply("openai")
            self.assertEqual(self.values()["model"], "gpt-official")
            self.apply("vendor_a")
            self.assertEqual(self.values()["model"], "model-a")

    def test_multiline_toml_refused_unchanged(self):
        for text in ['model = """gpt-official"""\n', 'model = [\n"gpt-official"\n]\n']:
            with self.subTest(text=text):
                put(self.path, text)
                with self.assertRaises(ValueError):
                    config.split_config(text)
                self.assertEqual(storage.read_text(self.path), text)

    def test_duplicate_root_keys_rejected(self):
        with self.assertRaises(ValueError):
            config.parse('model="one"\n"model"="two"')

    def test_profile_selector_rejected_before_modification(self):
        put(self.path, self.original + '\n[profiles.foo]\nmodel="gpt-other"\n')
        text = 'profile="foo"\n' + storage.read_text(self.path)
        put(self.path, text)
        with self.assertRaisesRegex(ValueError, "profile"):
            self.apply("vendor_a", self.store(self.profile()))
        self.assertEqual(storage.read_text(self.path), text)

    def test_existing_provider_collision_kept(self):
        put(self.path, self.original + '\n[model_providers.vendor_a]\nname="manual"\n')
        before = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, "同名"):
            self.apply("vendor_a", self.store(self.profile()))
        self.assertEqual(self.path.read_bytes(), before)

    def test_broken_managed_marker_rejected(self):
        with self.assertRaises(ValueError):
            config.strip_blocks('# CODEX-PROFILES-BEGIN\n')

    def test_array_continuations_do_not_hide_root_keys(self):
        text = 'notify = [\n "app.exe",\n "turn-ended"\n]\nmodel="gpt-old"\n'
        roots, _ = config.split_config(text)
        self.assertEqual(config.root_values(roots)["model"], "gpt-old")

    def test_official_candidates_nested_defaults_whitelist_priority(self):
        put(self.home / ".codex-global-state.json", {"model-picker": {"default_model_slug": "gpt-default-wm", "eligible_codex_model_slugs": ["gpt-list"]}})
        put(self.home / "models_cache.json", {"models": [{"slug": "gpt-low", "priority": 8}, {"slug": "gpt-high", "priority": 1}, {"slug": "gpt-hidden", "priority": 0, "visibility": "hide"}, {"slug": "deepseek-flash"}]})
        self.assertEqual(config.official_candidates(self.home), ["gpt-default", "gpt-list", "gpt-high", "gpt-low"])

    def test_unknown_official_migration_fails_before_writes(self):
        put(self.path, 'notify=[]\n')
        self.apply("vendor_a", self.store(self.profile()))
        before = self.path.read_bytes()
        with self.assertRaisesRegex(ValueError, "明确的官方模型"):
            self.apply("openai", migrate_chats=True, official_model="deepseek-flash")
        self.assertEqual(self.path.read_bytes(), before)
        self.apply("openai", migrate_chats=True, official_model="gpt-explicit")


@unittest.skipUnless(os.name == "nt", "Windows DPAPI")
class CredentialTests(HomeTest):
    def test_dpapi_roundtrip_and_tamper(self):
        secret = "dummy-密钥-with-unicode"
        sealed = credentials.encrypt(secret)
        self.assertNotIn(secret, sealed)
        self.assertEqual(credentials.decrypt(sealed), secret)
        with self.assertRaises(ValueError):
            credentials.decrypt("bad-ciphertext")

    def test_powershell_legacy_ciphertext_and_reverse_interop(self):
        text = "$s=ConvertTo-SecureString 'dummy-interop' -AsPlainText -Force; ConvertFrom-SecureString $s"
        script_path = self.home / "encrypt.ps1"
        put(script_path, text)
        result = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script_path)], capture_output=True, text=True, env=powershell_env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(credentials.decrypt(result.stdout.strip()), "dummy-interop")
        key = self.home / "key.txt"
        put(key, credentials.encrypt("dummy-python-secret"))
        script = "$s=ConvertTo-SecureString ([IO.File]::ReadAllText($args[0]));$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);try{[Console]::Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($p))}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}"
        script_path = self.home / "decrypt.ps1"
        # Windows PowerShell 5.1 requires BOM for non-ASCII scripts; this script is ASCII.
        put(script_path, script)
        result = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script_path), str(key)], capture_output=True, text=True, check=True, env=powershell_env())
        self.assertEqual(result.stdout, "dummy-python-secret")

    def test_helper_is_standalone_and_emits_only_secret(self):
        self.apply("vendor_a", self.store(self.profile()))
        auth = self.values()["model_providers"]["vendor_a"]["auth"]
        result = subprocess.run([auth["command"], *auth["args"]], cwd=self.home, capture_output=True, check=True)
        self.assertEqual(result.stdout, b"dummy-secret-a")
        self.assertEqual(result.stderr, b"")
        self.assertNotIn("powershell", auth["command"].lower())

    def test_helper_failure_never_emits_secret(self):
        helper = Path(credentials.__file__)
        result = subprocess.run([sys.executable, "-I", str(helper), "--emit-key", str(self.home / "missing")], capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")


class ProfileTests(HomeTest):
    def test_multiple_providers_isolated_keys_and_edit(self):
        store = self.store(self.profile(), self.profile("vendor_b", "model-b", "dummy-secret-b"))
        self.apply("vendor_a", store)
        self.apply("vendor_b")
        store = profiles.load_store(self.path)
        previous = store["profiles"][0]
        edited = profiles.new_profile("vendor_a", "新名称", "https://new.invalid", "new-model", previous=previous)
        self.assertEqual(edited["credential"], previous["credential"])
        profiles.set_profile(store, edited)
        self.apply("vendor_a", store)
        self.assertEqual(self.values()["model"], "new-model")
        for name, expected in (("vendor_a", "dummy-secret-a"), ("vendor_b", "dummy-secret-b")):
            self.assertEqual(credentials.decrypt(storage.read_text(profiles.tool_dir(self.path) / "keys" / (name + ".key"))), expected)

    def test_save_only_does_not_modify_config_or_history(self):
        session = self.home / "sessions" / "rollout-one.jsonl"
        rollout(session, [meta()])
        before = session.read_bytes()
        store = self.store(self.profile())
        profiles.save_store(self.path, store)
        self.assertEqual(self.path.read_text(encoding="utf-8"), self.original)
        self.assertEqual(session.read_bytes(), before)

    def test_default_switch_does_not_require_or_modify_database(self):
        session = self.home / "sessions" / "rollout-one.jsonl"
        rollout(session, [meta()])
        before = session.read_bytes()
        with patch("codex_switcher.profiles.migrate", side_effect=AssertionError("must not migrate")):
            self.apply("vendor_a", self.store(self.profile()))
        self.assertEqual(session.read_bytes(), before)

    def test_invalid_inputs(self):
        for identifier in ("openai", "codex_switcher_deepseek", "../bad", "ABC", "a" * 65):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                self.profile(identifier)
        for url in ("http://example.com", "https://u:p@example.com", "https://example.com?q=a", "https://example.com/#frag", "https://example.com/ bad", "https://example.com:bad"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                profiles.validate_url(url)
        for model in ("", 'bad"model', "模型"):
            with self.subTest(model=model), self.assertRaises(ValueError):
                self.profile(model=model)

    def test_store_revision_prevents_overwriting_another_save(self):
        first, stale = self.store(self.profile()), self.store(self.profile("vendor_b"))
        profiles.save_store(self.path, first)
        before = (profiles.tool_dir(self.path) / "providers.json").read_bytes()
        with self.assertRaisesRegex(RuntimeError, "重新加载"):
            profiles.save_store(self.path, stale)
        self.assertEqual((profiles.tool_dir(self.path) / "providers.json").read_bytes(), before)

    def test_legacy_state_and_alias_import(self):
        directory = profiles.tool_dir(self.path)
        put(directory / "state.json", {"mode": "deepseek", "apiBase": "https://legacy.invalid", "model": "deepseek-flash", "officialRoot": ['model="gpt-official"'], "officialModel": "gpt-official"})
        put(directory / "deepseek.key", credentials.encrypt("dummy-legacy-secret"))
        put(self.path, 'model_provider="deepseek"\nmodel="deepseek-flash"\n# CODEX-SWITCHER-BEGIN\n[model_providers.deepseek]\nname="old"\n[model_providers.codex_switcher_deepseek]\nname="alias"\n# CODEX-SWITCHER-END\n')
        store = profiles.load_store(self.path)
        self.assertEqual(store["profiles"][0]["id"], "deepseek")
        self.apply("deepseek", store)
        self.apply("openai")
        self.apply("deepseek")
        self.assertIn("codex_switcher_deepseek", self.values()["model_providers"])

    def test_custom_catalog_capabilities_and_cached_fallback(self):
        catalog = self.home / "models.json"
        put(catalog, {"models": [{"slug": "model-a", "base_instructions": "instructions", "context_window": 65536, "supports_reasoning_summaries": True, "use_responses_lite": True}]})
        self.apply("vendor_a", self.store(self.profile(catalog=str(catalog))))
        self.assertEqual(self.values()["model_context_window"], 65536)
        self.assertTrue(self.values()["model_supports_reasoning_summaries"])
        catalog.unlink()
        self.apply("openai")
        self.apply("vendor_a")
        cached = Path(self.values()["model_catalog_json"])
        self.assertTrue(storage.read_json(cached)["models"][0]["use_responses_lite"])

    def test_catalog_validation_does_not_guess_metadata(self):
        catalog = self.home / "models.json"
        for value in ({"models": []}, {"models": [{"slug": "model-a"}]}, {"models": [{"slug": "other", "base_instructions": "x"}]}):
            put(catalog, value)
            with self.assertRaises(ValueError):
                self.profile(catalog=str(catalog))

    def test_missing_official_capture_refused(self):
        put(self.path, 'model_provider="manual"\nmodel="thirdparty"\n')
        with self.assertRaisesRegex(ValueError, "没有保存"):
            self.apply("openai")

    def test_provider_store_invalid_version_and_duplicate_ids(self):
        directory = profiles.tool_dir(self.path)
        for value in ({"version": 99, "profiles": []}, {"version": 1, "profiles": [{"id": "vendor_a"}, {"id": "vendor_a"}]}):
            put(directory / "providers.json", value)
            with self.assertRaises(ValueError):
                profiles.load_store(self.path)


class TransactionTests(HomeTest):
    def test_write_failure_rolls_back_config_store_keys_helper(self):
        self.apply("vendor_a", self.store(self.profile()))
        directory = profiles.tool_dir(self.path)
        watched = [self.path, directory / "providers.json", directory / "keys" / "vendor_a.key", directory / "profile-credential.py"]
        before = {p: p.read_bytes() for p in watched}
        store = profiles.load_store(self.path)
        profiles.set_profile(store, self.profile(key="dummy-new-key"))
        real_write = profiles.atomic_write
        def fail_config(path, value):
            if path == self.path:
                raise OSError("injected write failure")
            return real_write(path, value)
        with patch("codex_switcher.profiles.atomic_write", side_effect=fail_config), self.assertRaises(OSError):
            self.apply("vendor_a", store)
        self.assertEqual({p: p.read_bytes() for p in watched}, before)

    def test_new_files_removed_on_failed_first_switch(self):
        directory = profiles.tool_dir(self.path)
        with patch("codex_switcher.profiles.write_json", side_effect=OSError("injected")), self.assertRaises(OSError):
            self.apply("vendor_a", self.store(self.profile()))
        self.assertFalse((directory / "profile-credential.py").exists())
        self.assertFalse((directory / "keys" / "vendor_a.key").exists())
        self.assertEqual(storage.read_text(self.path), self.original)

    def test_external_config_edit_preserved(self):
        external = self.original + "\n# external edit\n"
        def progress(percent, message):
            if percent == 5:
                put(self.path, external)
        with self.assertRaisesRegex(RuntimeError, "外部修改已保留"):
            self.apply("vendor_a", self.store(self.profile()), progress=progress)
        self.assertEqual(storage.read_text(self.path), external)

    def test_external_store_edit_preserved(self):
        path = profiles.tool_dir(self.path) / "providers.json"
        external = '{"external":"edit"}'
        def progress(percent, message):
            if percent == 5:
                put(path, external)
        with self.assertRaisesRegex(RuntimeError, "外部修改已保留"):
            self.apply("vendor_a", self.store(self.profile()), progress=progress)
        self.assertEqual(storage.read_text(path), external)

    def test_switch_lock_is_nonblocking_and_released(self):
        directory = profiles.tool_dir(self.path)
        with storage.SwitchLock(directory):
            with self.assertRaises(RuntimeError):
                with storage.SwitchLock(directory):
                    pass
        with storage.SwitchLock(directory):
            pass

    def test_running_client_refused_without_config_change(self):
        with patch("codex_switcher.profiles.assert_closed", side_effect=RuntimeError("请先退出")), self.assertRaises(RuntimeError):
            self.apply("vendor_a", self.store(self.profile()))
        self.assertEqual(storage.read_text(self.path), self.original)

    def test_redacted_log_and_rotation(self):
        logger = storage.diagnostic_logger(self.home, ["dummy-secret-exact"])
        logger.error("secret=dummy-secret-exact key=sk-hidden-token Authorization: Bearer other-key")
        storage.close_logger(logger)
        text = storage.read_text(self.home / "runtime.log")
        for value in ("dummy-secret-exact", "sk-hidden-token", "other-key"):
            self.assertNotIn(value, text)
        self.assertIn("[REDACTED]", text)


class MigrationTests(HomeTest):
    def session(self, name="one", records=None, **kwargs):
        path = self.home / "sessions" / ("rollout-" + name + ".jsonl")
        rollout(path, records or [meta(name), {"ordinal": 1, "type": "turn_context", "payload": {"model": "gpt-old", "effort": "medium"}}], **kwargs)
        return path

    def run_migration(self):
        return migration.migrate(self.home, "vendor_a", "model-a", "high", self.home / "backup")

    def test_all_runtime_fields_hidden_reasoning_and_visible_history(self):
        visible = {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "可见消息\n原样保留"}]}}
        records = [meta(), {"ordinal": 1, "type": "turn_context", "payload": {"model": "gpt-old", "effort": "medium", "collaboration_mode": {"settings": {"model": "gpt-old", "reasoning_effort": "medium"}}}},
            {"type": "event_msg", "payload": {"type": "thread_settings_applied", "thread_settings": {"model": "gpt-old", "model_provider_id": "openai", "reasoning_effort": "medium", "service_tier": "fast", "collaboration_mode": {"settings": {"model": "gpt-old", "reasoning_effort": "medium"}}}}},
            {"type": "world_state", "payload": {"state": {"model": "gpt-old", "collaboration_mode": {"model": "gpt-old"}, "personality": {"model": "gpt-old"}}}},
            {"type": "compacted", "payload": {"resume_metadata": {"previous_turn_settings": {"model": "gpt-old", "model_provider_id": "openai", "reasoning_effort": "medium"}}}},
            {"type": "response_item", "payload": {"type": "reasoning", "id": "rs_hidden", "encrypted_content": "hidden", "content": [{"type": "reasoning_text", "text": "reason"}]}},
            {"type": "response_item", "payload": {"type": "function_call", "call_id": "tool_one", "id": "tool_one", "arguments": "{}"}},
            {"type": "response_item", "payload": {"type": "function_call_output", "call_id": "tool_one", "output": "unchanged"}},
            {"type": "token_usage_record", "payload": {"response_id": "resp_0123456789abcdef"}}, visible]
        path = self.session(records=records)
        stat = path.stat()
        stats = migration.rewrite(path, "vendor_a", "model-a", "high")
        updated = list(monitor.records(path))
        self.assertEqual(updated[-1], visible)
        self.assertEqual(updated[-2], records[-2])
        self.assertEqual(updated[0]["payload"]["base_instructions"], records[0]["payload"]["base_instructions"])
        self.assertEqual(updated[0]["payload"]["id"], "one")
        self.assertNotIn("encrypted_content", updated[5]["payload"])
        self.assertEqual(updated[6]["payload"]["call_id"], updated[7]["payload"]["call_id"])
        self.assertIsNone(updated[2]["payload"]["thread_settings"]["service_tier"])
        self.assertEqual(stats.route_changes, 17)
        self.assertEqual(path.stat().st_mtime_ns, stat.st_mtime_ns)
        migration.rewrite(path, "openai", "gpt-back", "medium")
        self.assertEqual(list(monitor.records(path))[5]["payload"]["content"], [])

    def test_noop_preserves_exact_bytes_and_newlines(self):
        for newline in (b"\n", b"\r\n"):
            for trailing in (True, False):
                with self.subTest(newline=newline, trailing=trailing):
                    path = self.session(records=[meta(provider="vendor_a"), {"type": "response_item", "payload": {"type": "message", "content": "大段原始文本"}}], newline=newline, trailing=trailing)
                    before = path.read_bytes()
                    stats = migration.rewrite(path, "vendor_a", "model-a", "high")
                    self.assertEqual(stats.changed_lines, 0)
                    self.assertEqual(path.read_bytes(), before)

    def test_damaged_sessions_skip_and_restore_index_routes(self):
        healthy = self.session()
        broken = []
        for name, content in (("empty", b""), ("invalid", b'{"type":'), ("wrong", b'{"type":"other"}'), ("missing", b'{"type":"session_meta","payload":{}}')):
            path = self.home / "sessions" / ("rollout-" + name + ".jsonl")
            put(path, content)
            broken.append(path)
        tail = self.session("tail", [meta("tail"), b'{"type":'])
        broken.append(tail)
        before = {p: p.read_bytes() for p in broken}
        dbpath = self.home / "state_5.sqlite"
        database(dbpath, [("one", healthy.relative_to(self.home)), *[(p.stem.removeprefix("rollout-"), p.relative_to(self.home)) for p in broken]])
        result = self.run_migration()
        self.assertEqual(len(result.skipped), 5)
        self.assertEqual(result.database_rows, 1)
        self.assertEqual({p: p.read_bytes() for p in broken}, before)
        with closing(sqlite3.connect(dbpath)) as db:
            routes = dict(db.execute("SELECT id, model_provider FROM threads"))
        self.assertEqual(routes.pop("one"), "vendor_a")
        self.assertEqual(set(routes.values()), {"openai"})

    def test_all_rewrites_fail_restores_everything(self):
        path = self.session(records=[meta(), b'{"type":'])
        dbpath = self.home / "state_5.sqlite"
        database(dbpath, [("one", path)])
        before = path.read_bytes()
        with self.assertRaisesRegex(ValueError, "所有会话文件"):
            self.run_migration()
        self.assertEqual(path.read_bytes(), before)
        with closing(sqlite3.connect(dbpath)) as db:
            self.assertEqual(db.execute("SELECT model_provider FROM threads").fetchone()[0], "openai")

    def test_missing_database_fails_without_changes(self):
        path = self.session()
        before = path.read_bytes()
        with self.assertRaisesRegex(ValueError, "没有找到"):
            self.run_migration()
        self.assertEqual(path.read_bytes(), before)

    def test_fork_chain_uses_actual_utf8_offsets_in_dependency_order(self):
        parent = self.session("z-parent")
        child = self.session("b-child", [meta("b-child", history_base={"thread_id": "z-parent", "end_ordinal_exclusive": 1, "end_byte_offset": 999}), {"ordinal": 1, "type": "turn_context", "payload": {"model": "gpt-old"}}])
        grandchild = self.session("a-grandchild", [meta("a-grandchild", history_base={"thread_id": "b-child", "end_ordinal_exclusive": 1, "end_byte_offset": 999}), {"ordinal": 1, "type": "turn_context", "payload": {"model": "gpt-old"}}])
        database(self.home / "state_5.sqlite", [(p.stem, p) for p in (parent, child, grandchild)])
        result = self.run_migration()
        self.assertEqual(result.forks_remapped, 2)
        for p, source in ((child, parent), (grandchild, child)):
            self.assertEqual(migration.header(p)["history_base"]["end_byte_offset"], migration.find_ordinal_offset(source, 1))

    def test_missing_fork_parent_rolls_back(self):
        path = self.session(records=[meta(history_base={"thread_id": "missing", "end_ordinal_exclusive": 1, "end_byte_offset": 4})])
        database(self.home / "state_5.sqlite", [("one", path)])
        before = path.read_bytes()
        with self.assertRaisesRegex(ValueError, "源会话"):
            self.run_migration()
        self.assertEqual(path.read_bytes(), before)

    def test_fork_cycle_rolls_back(self):
        first = self.session("first", [meta("first", history_base={"thread_id": "second", "end_ordinal_exclusive": 1, "end_byte_offset": 0}), {"ordinal": 1, "type": "turn_context", "payload": {"model": "gpt-old"}}])
        second = self.session("second", [meta("second", history_base={"thread_id": "first", "end_ordinal_exclusive": 1, "end_byte_offset": 0}), {"ordinal": 1, "type": "turn_context", "payload": {"model": "gpt-old"}}])
        database(self.home / "state_5.sqlite", [("first", first), ("second", second)])
        before = {p: p.read_bytes() for p in (first, second)}
        with self.assertRaisesRegex(ValueError, "循环依赖"):
            self.run_migration()
        self.assertEqual({p: p.read_bytes() for p in (first, second)}, before)

    def test_projection_and_wal_backup_restore(self):
        path = self.session()
        dbpath = self.home / "sqlite" / "state_5.sqlite"
        database(dbpath, [("one", path)])
        projection = self.home / "sqlite" / "thread_history_1.sqlite"
        with closing(sqlite3.connect(projection)) as db, db:
            for table in migration.PROJECTION_TABLES:
                db.execute(f"CREATE TABLE {table} (id TEXT)")
                db.execute(f"INSERT INTO {table} VALUES ('one')")
        with closing(sqlite3.connect(dbpath)) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("UPDATE threads SET title='WAL committed title'")
            writer.commit()
            result = self.run_migration()
        self.assertEqual(result.projection_rows, 4)
        with closing(sqlite3.connect(projection)) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM thread_items").fetchone()[0], 0)
        result.restore()
        with closing(sqlite3.connect(dbpath)) as db:
            self.assertEqual(db.execute("SELECT model_provider,title FROM threads").fetchone(), ("openai", "WAL committed title"))
        with closing(sqlite3.connect(projection)) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM thread_items").fetchone()[0], 1)

    def test_later_config_failure_restores_migration(self):
        path = self.session()
        dbpath = self.home / "state_5.sqlite"
        database(dbpath, [("one", path)])
        before = path.read_bytes()
        real = profiles.atomic_write
        def fail_config(target, data):
            if target == self.path:
                raise OSError("injected after migration")
            return real(target, data)
        with patch("codex_switcher.profiles.atomic_write", side_effect=fail_config), self.assertRaises(OSError):
            self.apply("vendor_a", self.store(self.profile()), migrate_chats=True)
        self.assertEqual(path.read_bytes(), before)
        with closing(sqlite3.connect(dbpath)) as db:
            self.assertEqual(db.execute("SELECT model_provider FROM threads").fetchone()[0], "openai")

    def test_archived_sessions_and_empty_home(self):
        result = self.run_migration()
        self.assertEqual(result.rollout_count, 0)
        path = self.home / "archived_sessions" / "rollout-archived.jsonl"
        rollout(path, [meta()])
        database(self.home / "state_5.sqlite", [("one", path)])
        result = self.run_migration()
        self.assertEqual(result.rollout_count, 1)
        self.assertEqual(migration.header(path)["model_provider"], "vendor_a")


class MonitorTests(HomeTest):
    def setUp(self):
        super().setUp()
        self.session = self.home / "sessions" / "rollout-one.jsonl"
        self.response = "12345678-1234-1234-1234-123456789012"
        rollout(self.session, [meta(provider="vendor_a"), {"type": "event_msg", "payload": {"type": "thread_settings_applied", "thread_settings": {"model": "vendor-model", "model_provider_id": "vendor_a", "reasoning_effort": "high"}}},
             {"type": "token_usage_record", "timestamp": "2026-10-30T12:00:00Z", "payload": {"response_id": "resp_0123456789abcdef"}},
             {"type": "turn_context", "payload": {"model": "different-model", "effort": "medium"}},
             {"type": "token_usage_record", "timestamp": "2026-10-30T12:01:00Z", "payload": {"response_id": self.response}}])

    def test_actual_thread_separate_from_defaults_and_full_timeline(self):
        before = self.session.read_bytes()
        value = monitor.snapshot(self.home, full=True)
        self.assertEqual(value["provider"], "openai")
        self.assertEqual(value["threadProvider"], "vendor_a")
        self.assertEqual(value["threadModel"], "different-model")
        self.assertEqual(value["threadEffort"], "medium")
        self.assertEqual(value["originModel"], "gpt-origin")
        self.assertEqual(len(value["timeline"]), 2)
        self.assertIn("不能验证", value["conclusion"])
        self.assertEqual(self.session.read_bytes(), before)

    def test_tail_boundary_and_truncated_tail(self):
        with self.session.open("ab") as stream:
            stream.write(b'\n{"type":')
        self.assertEqual(monitor.response_ids(self.session, 180)[-1]["id"], self.response)

    def test_watch_log_uses_session_rather_than_config(self):
        value = monitor.snapshot(self.home)
        monitor.append_watch_log(self.home, value)
        row = json.loads(storage.read_text(profiles.tool_dir(self.path) / "provider-watch.log"))
        self.assertEqual(row["provider"], "vendor_a")
        self.assertNotIn("baseUrl", row)

    def test_fingerprint_is_only_format_classification(self):
        for identifier, expected in (("resp_0123456789abcdef", "OpenAI 格式"), (self.response, "UUID 格式"), ("unrecognized", "其他格式")):
            self.assertIn(expected, monitor.fingerprint_kind(identifier))

    def test_scan_all_includes_damaged_files(self):
        put(self.home / "sessions" / "rollout-bad.jsonl", b"broken")
        rows = monitor.scan_all(self.home)
        self.assertEqual(len(rows), 2)
        self.assertTrue(any("problem" in r for r in rows))

    def test_cli_status_and_list_do_not_expose_credentials(self):
        profiles.save_store(self.path, self.store(self.profile()))
        for command in (["check", "--json", "--full"], ["list", "--json"]):
            result = subprocess.run([sys.executable, "-X", "utf8", "-m", "codex_switcher", "--config", str(self.path), *command], capture_output=True, check=True)
            text = result.stdout.decode("utf-8")
            self.assertNotIn("dummy-secret", text)
            self.assertNotIn("credential", text)
            json.loads(text)


if __name__ == "__main__":
    unittest.main()
