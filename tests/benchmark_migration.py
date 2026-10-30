"""Reproducible synthetic migration benchmark and optional legacy C# comparison."""

import argparse
from dataclasses import asdict
from itertools import zip_longest
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from codex_switcher import migration


def sample_records():
    return [
        {"ordinal": 0, "type": "session_meta", "payload": {"id": "synthetic", "model_provider": "openai", "base_instructions": {"text": "Keep", "provenance": {"model": "gpt-original"}}}},
        {"ordinal": 1, "type": "turn_context", "payload": {"model": "gpt-original", "effort": "medium", "collaboration_mode": {"settings": {"model": "gpt-original", "reasoning_effort": "medium"}}}},
        {"type": "event_msg", "payload": {"type": "thread_settings_applied", "thread_settings": {"model": "gpt-original", "model_provider_id": "openai", "reasoning_effort": "medium", "service_tier": "fast", "collaboration_mode": {"settings": {"model": "gpt-original", "reasoning_effort": "medium"}}}}},
        {"type": "world_state", "payload": {"state": {"model": "gpt-original", "collaboration_mode": {"model": "gpt-original"}, "personality": {"model": "gpt-original"}}}},
        {"type": "compacted", "payload": {"resume_metadata": {"previous_turn_settings": {"model": "gpt-original", "model_provider_id": "openai", "reasoning_effort": "medium"}}, "replacement_history": [{"type": "reasoning", "id": "rs_secret", "encrypted_content": "hidden", "content": [{"type": "reasoning_text", "text": "summary"}]}, {"type": "function_call", "id": "tool_nested", "call_id": "tool_nested", "arguments": "{}"}]}},
        {"type": "response_item", "payload": {"type": "custom_tool_call", "id": "tool_one", "call_id": "tool_one", "input": "保留输入"}},
        {"type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "tool_one", "output": "保留输出"}},
        {"type": "response_item", "payload": {"type": "tool_search_call", "id": "tool_search", "call_id": "tool_search"}},
        {"type": "response_item", "payload": {"type": "tool_search_output", "call_id": "tool_search"}},
        {"type": "response_item", "payload": {"type": "function_call", "id": "tool_fn", "call_id": "tool_fn", "arguments": '{"a":1}'}},
        {"type": "response_item", "payload": {"type": "function_call_output", "call_id": "tool_fn", "output": "visible"}},
        {"type": "token_usage_record", "payload": {"response_id": "resp_0123456789abcdef", "tokens": 123456}},
        {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "可见内容\n" + "abcdefghij" * 180}], "future_field": {"integer": 9007199254740993, "decimal": 1.23456789, "nothing": None}}},
    ]


def compare_legacy(source: Path, python_file: Path, provider: str, model: str, effort: str):
    reference = source.with_name(source.stem + "-csharp.jsonl")
    shutil.copy2(source, reference)
    script = source.parent / "compare.ps1"
    script.write_text('''param($Source,$InputFile,$Provider,$Model,$Effort)
$ErrorActionPreference='Stop'
Add-Type -Path $Source
$watch=[Diagnostics.Stopwatch]::StartNew()
$result=[CodexSwitcherRollout]::RewriteFile($InputFile,$Provider,$Model,$Effort)
if($result.Changed){[IO.File]::Replace($result.TempPath,$InputFile,[Management.Automation.Language.NullString]::Value)}
@{seconds=$watch.Elapsed.TotalSeconds; route_changes=$result.RouteChanges; compatibility_changes=$result.CompatibilityChanges; lines=$result.Lines; changed_lines=$result.ChangedLines}|ConvertTo-Json -Compress
''', encoding="utf-8", newline="\n")
    env = {k: v for k, v in os.environ.items() if k.upper() != "PSMODULEPATH"}
    process = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script),
                              str(Path(__file__).resolve().parents[1] / "legacy" / "ChatMigration.cs"),
                              str(reference), provider, model, effort], env=env, capture_output=True, timeout=120)
    if process.returncode:
        raise RuntimeError(process.stderr.decode("utf-8", errors="replace"))
    statistics = json.loads(process.stdout)
    with python_file.open("rb") as left, reference.open("rb") as right:
        for number, (a, b) in enumerate(zip_longest(left, right), 1):
            if a is None or b is None or json.loads(a) != json.loads(b):
                raise AssertionError(f"Python/C# semantic mismatch at line {number}")
    return statistics


def run(megabytes, legacy):
    results = []
    with tempfile.TemporaryDirectory(prefix="switcher-benchmark-") as directory:
        root = Path(directory)
        base = sample_records()
        for newline, trailing, provider in ((b"\n", True, "vendor_a"), (b"\r\n", False, "openai")):
            source = root / (provider + ".jsonl")
            target_bytes = int(megabytes * 1024**2)
            block = newline.join(json.dumps(r, ensure_ascii=False).encode("utf-8") for r in base[1:]) + newline
            with source.open("wb") as stream:
                stream.write(json.dumps(base[0], ensure_ascii=False).encode("utf-8") + newline)
                while stream.tell() < target_bytes:
                    stream.write(block)
            if not trailing:
                with source.open("r+b") as stream:
                    stream.truncate(source.stat().st_size - len(newline))
            destination = root / (provider + "-python.jsonl")
            shutil.copy2(source, destination)
            model, effort = ("model-a", "high") if provider != "openai" else ("gpt-target", "medium")
            started = time.perf_counter()
            stats = migration.rewrite(destination, provider, model, effort)
            seconds = time.perf_counter() - started
            result = {"provider": provider, "bytes": source.stat().st_size, "python_seconds": round(seconds, 3), **asdict(stats)}
            if legacy:
                old = compare_legacy(source, destination, provider, model, effort)
                for key, value in asdict(stats).items():
                    if old[key] != value:
                        raise AssertionError(f"Statistics differ for {key}: Python={value}; C#={old[key]}")
                result.update(legacy_seconds=round(old["seconds"], 3), semantic_comparison="PASS")
            results.append(result)
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--megabytes", type=float, default=24)
    parser.add_argument("--legacy", action="store_true")
    args = parser.parse_args()
    if args.megabytes <= 0:
        parser.error("--megabytes must be positive")
    print(json.dumps(run(args.megabytes, args.legacy), ensure_ascii=False, indent=2))
