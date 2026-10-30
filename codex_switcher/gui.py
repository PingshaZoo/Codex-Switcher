"""Responsive Chinese Tkinter UI with queue-based background operations."""

from __future__ import annotations

from copy import deepcopy
import os
from pathlib import Path
import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText

from .credentials import decrypt
from .monitor import append_watch_log, snapshot
from .profiles import (fetch_models, load_store, new_profile, save_store, set_profile,
                       switch, tool_dir)
from .storage import diagnostic_logger, close_logger


class SwitcherApp:
    def __init__(self, root: tk.Tk, config: Path):
        self.root = root
        root.title("Codex 多供应商切换 · Python")
        root.geometry("850x770")
        root.minsize(760, 700)
        root.option_add("*Font", ("Microsoft YaHei UI", 10))
        style = ttk.Style(root)
        if "vista" in style.theme_names():
            style.theme_use("vista")
        style.configure("Title.TLabel", font=("Microsoft YaHei UI", 17, "bold"))
        style.configure("Hint.TLabel", foreground="#526071")
        self.config = tk.StringVar(value=str(config))
        self.status = tk.StringVar(value="正在加载供应商档案…")
        self.fields = {name: tk.StringVar() for name in ("id", "name", "baseUrl", "key", "models", "catalog")}
        self.migrate = tk.BooleanVar(value=False)
        self.events = queue.Queue()
        self.busy = False
        self.closed = False
        self.store = None
        self.loaded_path = None
        self.monitor = None
        self.controls = []
        self.entries = {}
        self.editing_id = None

        content = ttk.Frame(root, padding=22)
        content.pack(fill="both", expand=True)
        content.columnconfigure(0, weight=1)
        ttk.Label(content, text="Codex 多供应商切换", style="Title.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(content, text="保存供应商、切换模型，并查看会话里的运行时记录。", style="Hint.TLabel").grid(row=1, column=0, sticky="w", pady=(4, 15))

        configuration = ttk.LabelFrame(content, text="生效配置", padding=10)
        configuration.grid(row=2, column=0, sticky="ew")
        configuration.columnconfigure(0, weight=1)
        self.config_entry = ttk.Entry(configuration, textvariable=self.config)
        self.config_entry.grid(row=0, column=0, sticky="ew", padx=(0, 8))
        self._button(configuration, "选择文件", self._browse_config).grid(row=0, column=1)
        self._button(configuration, "重新加载", self._load).grid(row=0, column=2, padx=(8, 0))
        self.controls.append(self.config_entry)
        self.config_entry.bind("<FocusOut>", lambda event: self._load() if not self.busy and self._path() != self.loaded_path else None)

        editor = ttk.LabelFrame(content, text="供应商档案", padding=12)
        editor.grid(row=3, column=0, sticky="nsew", pady=(14, 10))
        content.rowconfigure(3, weight=1)
        editor.columnconfigure(1, weight=1)
        picker = ttk.Frame(editor)
        picker.grid(row=0, column=0, columnspan=3, sticky="ew", pady=(0, 12))
        picker.columnconfigure(0, weight=1)
        self.profiles = ttk.Combobox(picker, state="readonly")
        self.profiles.grid(row=0, column=0, sticky="ew")
        self.profiles.bind("<<ComboboxSelected>>", lambda event: self._select())
        self.controls.append(self.profiles)
        self._button(picker, "新增", self._new).grid(row=0, column=1, padx=(8, 0))
        self._button(picker, "保存修改", self._save).grid(row=0, column=2, padx=(8, 0))

        labels = (("id", "供应商 ID"), ("name", "显示名称"), ("baseUrl", "HTTPS 接口"),
                  ("key", "API Key"), ("models", "模型列表"), ("catalog", "模型目录 JSON"))
        for row, (name, label) in enumerate(labels, 1):
            ttk.Label(editor, text=label).grid(row=row, column=0, sticky="w", padx=(0, 14), pady=6)
            entry = ttk.Entry(editor, textvariable=self.fields[name], show="●" if name == "key" else "")
            entry.grid(row=row, column=1, sticky="ew", pady=6)
            self.entries[name] = entry
            self.controls.append(entry)
            if name == "models":
                self._button(editor, "获取模型", self._fetch).grid(row=row, column=2, padx=(8, 0))
            if name == "catalog":
                self._button(editor, "浏览…", self._browse_catalog).grid(row=row, column=2, padx=(8, 0))
        ttk.Label(editor, text="密钥留空沿用；模型用逗号分隔，第一个为默认模型。\n目录可留空；填写时使用该供应商提供的完整能力目录。", style="Hint.TLabel").grid(
            row=7, column=0, columnspan=3, sticky="w", pady=(10, 0))

        self.migration_box = ttk.Checkbutton(content, text="同时迁移全部历史会话（默认关闭）", variable=self.migrate)
        self.migration_box.grid(row=4, column=0, sticky="w", pady=(2, 4))
        self.controls.append(self.migration_box)
        notice = ttk.Label(content, text="切换前请正常退出 Codex / ChatGPT，完成后重新打开。\n默认只切换新对话配置；迁移历史会改写全部本地会话，并清理无法跨供应商复用的隐藏推理状态。", style="Hint.TLabel", wraplength=780)
        notice.grid(row=5, column=0, sticky="ew", pady=(0, 10))
        root.bind("<Configure>", lambda event: notice.configure(wraplength=max(400, root.winfo_width() - 54)) if event.widget == root else None)
        self.progress = ttk.Progressbar(content, maximum=100)
        self.progress.grid(row=6, column=0, sticky="ew", pady=(0, 12))
        actions = ttk.Frame(content)
        actions.grid(row=7, column=0, sticky="ew")
        actions.columnconfigure((0, 1), weight=1)
        self._button(actions, "切换到官方登录", lambda: self._switch(True)).grid(row=0, column=0, sticky="ew", ipady=7, padx=(0, 5))
        self._button(actions, "切换到所选供应商", lambda: self._switch(False)).grid(row=0, column=1, sticky="ew", ipady=7, padx=(5, 0))
        self._button(content, "请求去向监测 · 默认配置 / 会话运行时 / 响应记录", self._open_monitor).grid(
            row=8, column=0, sticky="ew", ipady=6, pady=(10, 8))
        ttk.Label(content, textvariable=self.status, style="Hint.TLabel", wraplength=740).grid(row=9, column=0, sticky="ew")
        root.protocol("WM_DELETE_WINDOW", self._close)
        self._load()
        self.poll_timer = root.after(60, self._poll)

    def _button(self, parent, text, command):
        button = ttk.Button(parent, text=text, command=command)
        self.controls.append(button)
        return button

    def _path(self):
        return Path(self.config.get()).expanduser().resolve()

    def _load(self, selected=None):
        try:
            self.store = load_store(self._path())
            self.loaded_path = self._path()
            self.profile_ids = ["openai"] + [p["id"] for p in self.store["profiles"]]
            self.profiles["values"] = ["OpenAI 官方登录"] + [f"{p['name']} [{p['id']}]" for p in self.store["profiles"]]
            identifier = selected or self.store.get("selected", "openai")
            self.profiles.current(self.profile_ids.index(identifier) if identifier in self.profile_ids else 0)
            self._select()
        except Exception as exc:
            self.store = None
            self.status.set("加载失败：" + str(exc))

    def _select(self):
        if self.store is None or self.profiles.current() < 0:
            return
        identifier = self.profile_ids[self.profiles.current()]
        self.editing_id = identifier
        self.entries["id"].configure(state="normal")
        for variable in self.fields.values():
            variable.set("")
        self.fields["id"].set(identifier)
        if identifier == "openai":
            self.fields["name"].set("OpenAI 官方登录")
            self.status.set("官方登录复用已有 ChatGPT 登录。迁移历史时可在模型栏填写目标 gpt-* 模型。")
        else:
            profile = next(p for p in self.store["profiles"] if p["id"] == identifier)
            for name in ("id", "name", "baseUrl", "catalog"):
                self.fields[name].set(profile.get(name, ""))
            self.fields["models"].set(", ".join(profile["models"]))
            if profile.get("catalog") and not Path(profile["catalog"]).is_file():
                cached = tool_dir(self._path()) / "catalogs" / (identifier + ".json")
                if cached.is_file():
                    self.fields["catalog"].set(str(cached))
            self.status.set("已加载：" + profile["name"] + "；密钥已加密保存，留空沿用。")
        self.entries["id"].configure(state="readonly")

    def _new(self):
        self.profiles.set("")
        self.editing_id = None
        self.entries["id"].configure(state="normal")
        for variable in self.fields.values():
            variable.set("")
        self.entries["id"].focus_set()
        self.status.set("填写 ID、名称、HTTPS 接口、模型和密钥，然后保存或切换。")

    def _draft(self):
        if self.store is None:
            raise ValueError("请先选择并加载有效配置。")
        if self._path() != self.loaded_path:
            raise ValueError("配置路径已改变，请先重新加载供应商档案。")
        identifier = self.fields["id"].get().strip()
        if self.editing_id and identifier != self.editing_id:
            raise ValueError("保存后的供应商 ID 不可修改，请新增另一份档案。")
        previous = next((p for p in self.store["profiles"] if p["id"] == identifier), None)
        profile = new_profile(identifier, self.fields["name"].get(), self.fields["baseUrl"].get().strip(),
                              self.fields["models"].get(), self.fields["key"].get(),
                              self.fields["catalog"].get().strip(), previous)
        draft = deepcopy(self.store)
        set_profile(draft, profile)
        return draft, identifier

    def _error(self, exc):
        logger = diagnostic_logger(tool_dir(self._path()), [self.fields["key"].get()])
        logger.error("UI operation failed: %s", exc)
        close_logger(logger)
        self.status.set("未完成；请查看 runtime.log。")
        messagebox.showerror("未完成", str(exc) + "\n日志：" + str(tool_dir(self._path()) / "runtime.log"), parent=self.root)

    def _save(self):
        try:
            draft, identifier = self._draft()
            path = self._path()
            self._task(lambda: save_store(path, draft), lambda value: self._saved(identifier))
        except Exception as exc:
            self._error(exc)

    def _saved(self, identifier):
        self.fields["key"].set("")
        self._load(identifier)
        self.status.set("档案已保存；点击切换后才会应用到 Codex。")

    def _switch(self, official):
        try:
            if self.store is None:
                raise ValueError("请先加载有效配置。")
            if self._path() != self.loaded_path:
                raise ValueError("配置路径已改变，请先重新加载供应商档案。")
            draft, identifier = (deepcopy(self.store), "openai") if official else self._draft()
            path, migrate_chats = self._path(), self.migrate.get()
            model = self.fields["models"].get().strip()
            events = self.events
            self._task(lambda: switch(path, draft, identifier, migrate_chats, model,
                                      lambda percent, message: events.put(("progress", (percent, message)))),
                       self._switched)
        except Exception as exc:
            self._error(exc)

    def _switched(self, result):
        self.fields["key"].set("")
        self._load()
        text = f"切换成功：{result['provider']} / {result['model'] or '官方默认'}\n耗时：{result['seconds']} 秒\n备份：{result['backup']}\n请重新打开 Codex。"
        if result["skipped"]:
            text += "\n跳过损坏会话 " + str(len(result["skipped"])) + " 个：\n" + "\n".join(
                f"{Path(s['path']).name}: {s['reason']}" for s in result["skipped"][:8])
        self.status.set("切换完成，请重启 Codex。")
        messagebox.showinfo("切换完成", text, parent=self.root)

    def _fetch(self):
        try:
            secret = self.fields["key"].get()
            if not secret:
                previous = next((p for p in (self.store or {}).get("profiles", []) if p["id"] == self.fields["id"].get()), None)
                if previous is None:
                    raise ValueError("请填写 API Key。")
                secret = decrypt(previous["credential"])
            url = self.fields["baseUrl"].get().strip()
            self._task(lambda: fetch_models(url, secret), self._fetched)
        except Exception as exc:
            self._error(exc)

    def _fetched(self, models):
        self.fields["models"].set(", ".join(models))
        self.status.set("模型列表已读取；保存或切换后生效。这不代表 Responses 推理已通过验证。")

    def _task(self, function, done):
        if self.busy:
            return
        self.busy = True
        self.done = done
        self.progress["value"] = 0
        self.status.set("正在处理，请稍候…")
        for control in self.controls:
            control.configure(state="disabled")
        events = self.events

        def worker():
            try:
                events.put(("done", function()))
            except Exception as exc:
                events.put(("error", exc))
        threading.Thread(target=worker, daemon=False).start()

    def _poll(self):
        if self.closed:
            return
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == "progress":
                    self.progress["value"], message = value
                    self.status.set(message)
                    continue
                self.busy = False
                done, self.done = self.done, None
                for control in self.controls:
                    control.configure(state="normal")
                self.profiles.configure(state="readonly")
                self.entries["id"].configure(state="readonly" if self.editing_id else "normal")
                if kind == "error":
                    self._error(value)
                else:
                    self.progress["value"] = 100
                    try:
                        done(value)
                    except Exception as exc:
                        self._error(exc)
        except queue.Empty:
            pass
        self.poll_timer = self.root.after(60, self._poll)

    def _browse_config(self):
        path = filedialog.askopenfilename(parent=self.root, title="选择生效的 config.toml", filetypes=[("TOML", "*.toml"), ("所有文件", "*.*")])
        if path:
            self.config.set(path)
            self._load()

    def _browse_catalog(self):
        path = filedialog.askopenfilename(parent=self.root, title="选择供应商模型能力目录", filetypes=[("JSON", "*.json")])
        if path:
            self.fields["catalog"].set(path)

    def _open_monitor(self):
        if self.monitor and self.monitor.window.winfo_exists() and self.monitor.config != self._path():
            self.monitor.close()
        if self.monitor and self.monitor.window.winfo_exists():
            self.monitor.window.lift()
        else:
            self.monitor = MonitorWindow(self.root, self._path())

    def _close(self):
        if self.busy:
            self.status.set("操作正在进行，请等待完成后再关闭窗口。")
            return
        if self.monitor:
            self.monitor.close()
        self.closed = True
        self.done = None
        self.root.after_cancel(self.poll_timer)
        self.root.destroy()


class MonitorWindow:
    def __init__(self, parent, config):
        self.config = config
        self.window = tk.Toplevel(parent)
        self.window.title("Codex 请求去向监测")
        self.window.geometry("1000x650")
        self.window.minsize(700, 420)
        self.window.protocol("WM_DELETE_WINDOW", self.close)
        self.full = tk.BooleanVar(value=False)
        self.paused, self.busy, self.closed = False, False, False
        self.last_response = None
        self.events = queue.Queue()
        self.timer = None
        bar = ttk.Frame(self.window, padding=10)
        bar.pack(fill="x")
        ttk.Checkbutton(bar, text="完整时间线（较慢）", variable=self.full, command=self.refresh).pack(side="left")
        self.pause_button = ttk.Button(bar, text="暂停", command=self.toggle)
        self.pause_button.pack(side="left", padx=8)
        ttk.Button(bar, text="立即刷新", command=self.refresh).pack(side="left")
        ttk.Button(bar, text="打开监测日志", command=self.open_log).pack(side="right")
        self.headline = tk.StringVar(value="正在读取会话记录…")
        ttk.Label(self.window, textvariable=self.headline, padding=(12, 4), wraplength=900).pack(fill="x")
        self.text = ScrolledText(self.window, wrap="word", font=("Microsoft YaHei UI", 10), state="disabled")
        self.text.pack(fill="both", expand=True, padx=12, pady=12)
        self.refresh()
        self._poll()

    def toggle(self):
        self.paused = not self.paused
        self.pause_button.configure(text="继续" if self.paused else "暂停")
        if self.paused and self.timer:
            self.window.after_cancel(self.timer)
            self.timer = None
        elif not self.paused:
            self.refresh()

    def refresh(self):
        if self.closed or self.busy:
            return
        if self.timer:
            self.window.after_cancel(self.timer)
            self.timer = None
        self.busy = True
        full = self.full.get()
        config, events = self.config, self.events
        def worker():
            try:
                events.put(snapshot(config.parent, full=full, config_path=config))
            except Exception as exc:
                events.put(exc)
        threading.Thread(target=worker, daemon=True).start()

    def _poll(self):
        if self.closed:
            return
        try:
            value = self.events.get_nowait()
            self.busy = False
            if isinstance(value, Exception):
                self.headline.set("读取失败：" + str(value))
            else:
                self.headline.set(value["headline"])
                self.text.configure(state="normal")
                self.text.delete("1.0", "end")
                self.text.insert("1.0", "\n".join(value["lines"]))
                self.text.configure(state="disabled")
                key = (value["threadId"], value["lastId"])
                if value["lastId"] and key != self.last_response:
                    try:
                        append_watch_log(self.config.parent, value)
                        self.last_response = key
                    except OSError:
                        self.headline.set(value["headline"] + "（监测日志写入失败）")
            if not self.paused:
                self.timer = self.window.after(3000, self.refresh)
        except queue.Empty:
            pass
        self.poll_timer = self.window.after(80, self._poll)

    def open_log(self):
        path = tool_dir(self.config) / "provider-watch.log"
        if path.is_file():
            os.startfile(path)
        else:
            messagebox.showinfo("监测日志", "出现新的响应 ID 后会生成 provider-watch.log。", parent=self.window)

    def close(self):
        if self.closed:
            return
        self.closed = True
        for timer in (self.timer, getattr(self, "poll_timer", None)):
            if timer:
                self.window.after_cancel(timer)
        if self.window.winfo_exists():
            self.window.destroy()


def run(config: Path):
    root = tk.Tk()
    SwitcherApp(root, config)
    root.mainloop()
