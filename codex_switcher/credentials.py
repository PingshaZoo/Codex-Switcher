"""Standalone Windows DPAPI helper, compatible with PowerShell SecureString files.

This file is copied next to the active config. Keep it independent of this package.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import sys


class DataBlob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_ubyte))]


def _crypt(data: bytes, decrypt: bool) -> bytes:
    if os.name != "nt":
        raise RuntimeError("密钥加密仅支持 Windows 当前用户 DPAPI。")
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    crypt32.CryptProtectData.argtypes = [ctypes.POINTER(DataBlob), wintypes.LPCWSTR,
        ctypes.POINTER(DataBlob), ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD,
        ctypes.POINTER(DataBlob)]
    crypt32.CryptProtectData.restype = wintypes.BOOL
    crypt32.CryptUnprotectData.argtypes = [ctypes.POINTER(DataBlob), ctypes.c_void_p,
        ctypes.POINTER(DataBlob), ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD,
        ctypes.POINTER(DataBlob)]
    crypt32.CryptUnprotectData.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p
    buffer = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    source = DataBlob(len(data), buffer)
    output = DataBlob()
    try:
        call = crypt32.CryptUnprotectData if decrypt else crypt32.CryptProtectData
        if not call(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(output)):
            raise ctypes.WinError(ctypes.get_last_error())
        return ctypes.string_at(output.pbData, output.cbData)
    finally:
        ctypes.memset(buffer, 0, len(data))
        if output.pbData:
            ctypes.memset(output.pbData, 0, output.cbData)
            kernel32.LocalFree(output.pbData)


def encrypt(secret: str) -> str:
    if not secret or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in secret):
        raise ValueError("密钥不能为空，且不能含空白或控制字符。")
    return _crypt(secret.encode("utf-16-le"), False).hex()


def decrypt(credential: str) -> str:
    try:
        return _crypt(bytes.fromhex(credential.strip()), True).decode("utf-16-le")
    except (OSError, ValueError, UnicodeError) as exc:
        raise ValueError("无法解锁密钥，请在原 Windows 用户下重新填写 API Key。") from exc


def main(argv=None):
    parser = argparse.ArgumentParser(description="Codex credential helper")
    parser.add_argument("--emit-key", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        secret = decrypt(args.emit_key.read_text(encoding="utf-8-sig"))
        sys.stdout.buffer.write(secret.encode("utf-8"))
        sys.stdout.buffer.flush()
        return 0
    except Exception:
        print("Unable to unlock provider credential. Re-enter the key in Switcher.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
