"""Command-line entry point. Credentials are prompted, never accepted in argv."""

from __future__ import annotations

import argparse
from getpass import getpass
import json
from pathlib import Path
import sys

from . import __version__
from .platform import default_home
from .profiles import load_store, new_profile, set_profile, save_store, switch, tool_dir
from .monitor import snapshot, scan_all
from .storage import diagnostic_logger, close_logger


def parser():
    root = argparse.ArgumentParser(description="Codex 多供应商切换（Python 版）")
    root.add_argument("--version", action="version", version=__version__)
    root.add_argument("--config", type=Path, default=default_home() / "config.toml", help="生效的 config.toml")
    commands = root.add_subparsers(dest="command")
    commands.add_parser("gui", help="打开中文桌面界面")
    status = commands.add_parser("check", help="只读请求去向自查")
    status.add_argument("--scan-all", "-ScanAll", action="store_true")
    status.add_argument("--full", action="store_true")
    status.add_argument("--recent", type=int, default=8)
    status.add_argument("--json", action="store_true")
    listing = commands.add_parser("list", help="列出供应商（不输出密文或密钥）")
    listing.add_argument("--json", action="store_true")
    add = commands.add_parser("save", help="新增或修改供应商档案；密钥由交互提示输入")
    add.add_argument("id")
    add.add_argument("--name", required=True)
    add.add_argument("--url", required=True)
    add.add_argument("--models", required=True)
    add.add_argument("--catalog", default="")
    apply = commands.add_parser("switch", help="切换前必须退出 Codex / ChatGPT")
    apply.add_argument("id", help="供应商 ID，或 openai")
    apply.add_argument("--migrate-chats", action="store_true", help="同时迁移所有本地历史（默认关闭）")
    apply.add_argument("--official-model", default="")
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    config = args.config.expanduser().resolve()
    logger = diagnostic_logger()
    try:
        if args.command in (None, "gui"):
            from .gui import run
            run(config)
        elif args.command == "check":
            if args.recent < 1:
                raise ValueError("--recent 必须大于零。")
            value = scan_all(config.parent) if args.scan_all else snapshot(config.parent, recent=args.recent, full=args.full, config_path=config)
            if args.json or args.scan_all:
                print(json.dumps(value, ensure_ascii=False, indent=2))
            else:
                print("\n".join(value["lines"]))
        elif args.command == "list":
            store = load_store(config)
            value = {"selected": store["selected"], "profiles": [
                {k: p[k] for k in ("id", "name", "baseUrl", "models", "catalog")}
                for p in store["profiles"]]}
            if args.json:
                print(json.dumps(value, ensure_ascii=False, indent=2))
            else:
                print("当前：" + value["selected"] + "\nopenai  OpenAI 官方登录")
                for p in value["profiles"]:
                    print(f"{p['id']}  {p['name']}  {', '.join(p['models'])}")
        elif args.command == "save":
            store = load_store(config)
            previous = next((p for p in store["profiles"] if p["id"] == args.id), None)
            secret = getpass("API Key（留空沿用已保存密钥）：")
            profile = new_profile(args.id, args.name, args.url, args.models, secret, args.catalog, previous)
            set_profile(store, profile)
            save_store(config, store)
            print("供应商档案已保存；执行 switch 后生效。")
        elif args.command == "switch":
            result = switch(config, load_store(config), args.id, args.migrate_chats, args.official_model,
                            lambda percent, message: print(f"[{percent:3d}%] {message}", file=sys.stderr))
            print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:
        logger.exception("Command failed")
        # Network and credential operations expose intentionally generic failures.
        print(f"未完成：{exc}", file=sys.stderr)
        return 1
    finally:
        close_logger(logger)


if __name__ == "__main__":
    raise SystemExit(main())
