"""Windows process checks; no shell or PowerShell dependency."""

import ctypes
from ctypes import wintypes
import os
from pathlib import Path


def default_home() -> Path:
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser().resolve()


def active_clients() -> list[str]:
    if os.name != "nt":
        raise RuntimeError("本工具的切换功能仅支持 Windows。")

    class ProcessEntry(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
            ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
            ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
            ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", wintypes.LONG),
            ("dwFlags", wintypes.DWORD), ("szExeFile", wintypes.WCHAR * 260)]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    for name in ("Process32FirstW", "Process32NextW"):
        getattr(kernel, name).argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry)]
        getattr(kernel, name).restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    found = []
    try:
        entry = ProcessEntry()
        entry.dwSize = ctypes.sizeof(entry)
        present = kernel.Process32FirstW(snapshot, ctypes.byref(entry))
        while present:
            if entry.szExeFile.lower() in {"codex.exe", "chatgpt.exe"}:
                found.append(f"{entry.szExeFile} ({entry.th32ProcessID})")
            present = kernel.Process32NextW(snapshot, ctypes.byref(entry))
        error = ctypes.get_last_error()
        if error not in (0, 18):  # ERROR_NO_MORE_FILES is the normal end of enumeration.
            raise ctypes.WinError(error)
    finally:
        kernel.CloseHandle(snapshot)
    return found


def assert_closed():
    clients = active_clients()
    if clients:
        raise RuntimeError("请先正常退出 Codex / ChatGPT 桌面应用和 Codex 命令行：" + ", ".join(clients))
