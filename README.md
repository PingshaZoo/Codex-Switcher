# Codex 多供应商切换 · Python

Windows 桌面工具，用于在 ChatGPT 官方登录和多个 Responses API 供应商之间切换 Codex 配置。Python 3.11+，使用 Tkinter、sqlite3、tomllib、ctypes 等标准库，无第三方运行依赖。

## 启动

双击 `Start.cmd`，或在项目目录运行：

```console
python -X utf8 start_switcher.py
```

Python 安装需包含 Tcl/Tk。默认读取 `CODEX_HOME/config.toml`；未设置时使用当前用户的 `.codex/config.toml`。也可指定配置：

```console
python -X utf8 start_switcher.py --config D:\example\.codex\config.toml
```

启动失败会写 `%LOCALAPPDATA%/Codex-Switcher/logs/runtime.log`。业务日志写配置旁的 `codex-switcher/runtime.log`，不可写时回退到启动日志目录。日志超过 5 MB 时保留一份轮换文件。

## 使用

1. 从已完成 ChatGPT 官方登录的配置开始，先正常退出 Codex / ChatGPT 桌面应用和 Codex 命令行。
2. 新增供应商，填写唯一 ID、显示名称、HTTPS 基础接口、API Key 和模型列表。多个模型用逗号分隔，第一个为默认模型。
3. **保存修改**仅保存供应商档案；**切换到所选供应商**保存并应用配置。已保存 ID 固定；密钥留空沿用，输入新值更新密钥。
4. **获取模型**请求 `base_url/models`，失败可以手填。模型列表成功返回不代表 Responses 推理或工具调用通过验证。
5. 可选模型目录必须含 `models[]`、对应 `slug` 和 `base_instructions`。能力字段原样保留；不会为未知供应商推测能力或套用 DeepSeek 模板。接口必须支持 Responses API，本工具不转换 Chat Completions 协议。
6. 成功后重新打开 Codex。**切换到官方登录**恢复保存的官方模型根配置；官方根配置可以为空，不迁移历史时无需手填官方模型。

默认不改写历史会话。勾选 **同时迁移全部历史会话** 后，会迁移 `sessions`、`archived_sessions`、最新有效的 state SQLite 索引，并使会话投影缓存失效。旧会话的 ID、可见消息、工具结果、服务端响应 ID 和创建时模型记录保留；隐藏推理密文/标识及工具 ID 会做跨供应商兼容处理，目标接口仍可能不支持部分历史类型。

迁移到官方时，目标模型按保存的官方配置、保存的官方模型、明确填写的 `gpt-*`、本机官方模型记录确定；无法确定则在写入前报错。坏会话保持原字节并报告，对应索引恢复原路由；全部可处理会话均失败或 fork 无法修复时整体回滚。

`auth.json`、MCP、skills、插件与信任设置不变。复杂 TOML 多行字符串和托管根键多行值会拒绝编辑。存在 `profile` 选择器、重复键或手工定义的同名供应商时也会在写入前拒绝。

## 旧数据兼容与凭证

兼容 `codex-switcher/providers.json` v1，以及旧 `state.json` + `deepseek.key`。密钥使用 Windows 当前用户 DPAPI；Python 和旧 PowerShell 的十六进制 SecureString 密文可互读，不会要求所有供应商重新填写密钥。跨 Windows 用户或跨电脑需重新输入。

生效凭证是 `codex-switcher/keys/<id>.key`；独立 Python 凭证助手部署在配置旁的 `profile-credential.py`。Codex 调用切换时的 Python 解释器解密密钥；解释器需要保留在原位置，更换 Python 路径后重新应用一次配置。复制助手后无需依赖本项目所在目录。

生效能力目录缓存为 `codex-switcher/catalogs/<id>.json`，外部目录移动后可以继续使用已缓存副本。根目录保留的 `deepseek-models.json` 仅供已有 DeepSeek 配置选用。

## 请求去向监测

界面支持每 3 秒刷新、暂停、完整时间线和打开日志。默认配置与会话运行时模型分开显示；日志记录会话中的供应商和模型，不把当前默认配置当成历史请求去向。

响应 ID 格式只能提供线索，不能验证真实后端；可结合代理连接域名和供应商用量记录交叉验证。

```console
python -X utf8 start_switcher.py check --full
python -X utf8 start_switcher.py check --scan-all --json
```

也可双击 `检查当前对话.cmd`，或运行 `检查当前对话.cmd -ScanAll`。上述命令只读；图形监测遇到新响应时会追加 `provider-watch.log`。

## 命令行

全局 `--config` 放在子命令之前；密钥通过交互提示输入，避免进入命令行历史和进程参数。

```console
python -X utf8 start_switcher.py list --json
python -X utf8 start_switcher.py save vendor_a --name "供应商 A" --url https://example.com/v1 --models model-a,model-b
python -X utf8 start_switcher.py switch vendor_a
python -X utf8 start_switcher.py switch openai
python -X utf8 start_switcher.py switch openai --migrate-chats --official-model gpt-example
```

最后一条中的模型名是占位示例，应替换为账号实际可用的模型。也可用 `python -m codex_switcher`；可选 `python -m pip install .` 安装命令入口 `codex-switcher`（构建时会安装 setuptools，源码直接运行不需要安装）。

## 备份与恢复

每次应用之前保存 `codex-switcher/profile-backups/<时间-随机ID>/files.json` 与对应原文件；可选历史备份在同批 `chats/` 下，包含 SQLite 一致性备份、rollout 原文件与 `manifest.json`。保存档案也会备份先前的档案。

操作失败会自动恢复同批内容；恢复失败会明确报告备份路径。手工恢复前退出 Codex，依据同批清单恢复配置、档案、凭证助手、密钥、目录、state 和投影数据库、rollout。SQLite 备份使用在线 backup API，包括已提交的 WAL 数据；手工恢复应使用 SQLite backup API 或在确保数据库完全关闭后处理同名 WAL/SHM，不能在仍运行的客户端上只覆盖数据库文件。

备份可能包含原有 MCP 凭证和完整对话，请勿公开分享。工具用进程检查和互斥锁防止并发切换，遇到外部配置/档案修改时取消并保留外部修改。

## 开发与验证

```console
python -X utf8 -m unittest discover -s tests -p "test_*.py" -v
python -X utf8 tests/benchmark_migration.py --megabytes 24 --legacy
python -X utf8 tests/preview_gui.py
```

测试使用临时 Codex 目录和虚构密钥，不切换真实配置，不调用付费推理。GUI 测试需要 Windows 桌面会话。旧密文互通与旧引擎对照测试使用 Windows 自带 PowerShell，仅是验证依赖；新版运行不调用 PowerShell 或 C#。

`legacy/` 保留原 PowerShell/C# 实现和四组旧回归测试，供对照，不参与新版运行。设计与功能验收清单见 `docs/superpowers/specs/2026-10-30-python-refactor-design.md`。
