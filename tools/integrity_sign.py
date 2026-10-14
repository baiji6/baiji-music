#!/usr/bin/env python3
# ==============================================================================
# 白姬音乐 · 桌面端完整性清单签名（#78 签名校验）
# ------------------------------------------------------------------------------
# 用法: python3 tools/integrity_sign.py <app_dir> <private_key_pem> [version]
#
# 对 <app_dir> 下全部文件做 SHA-256 清单，用 ed25519 私钥签名后写入
# <app_dir>/integrity.manifest（应用启动时由 lib/core/signature_guard.dart
# 用内嵌公钥验签并逐文件比对）。
#
# 私钥: PKCS#8 PEM（openssl genpkey -algorithm ed25519），经 CI secret
#       INTEGRITY_SIGN_KEY_PEM 注入，不入库。对应公钥锚在 signature_guard.dart。
# 签名: openssl pkeyutl -sign -rawin（RFC 8032 Ed25519，与 Dart 端互通）。
#
# 各端调用位置（build.yml）:
#   macOS   : .app/Contents/（strip 之后、打 dmg 之前）
#   Windows : Release 目录（UPX 之后、打 zip / SFX 之前）
#   Linux   : bundle 目录（UPX 之后、打 deb 之前）
# 私钥未配置（secret 缺失）时打印警告并以退出码 2 结束——调用方据此跳过，
# 应用侧找不到清单会放行（旧产物 / 本地构建语义）。
# ==============================================================================
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile

MAGIC = 'baiji-integrity-v1'
MANIFEST = 'integrity.manifest'


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def collect_files(app_dir: str) -> dict:
    files = {}
    for root, dirs, names in os.walk(app_dir):
        dirs.sort()
        for name in sorted(names):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, app_dir).replace(os.sep, '/')
            if rel == MANIFEST:
                continue
            # 符号链接（如 macOS Frameworks 内部链接）不参与：它们指向
            # 清单内其它文件，本体已覆盖；写死哈希反而随打包顺序变化
            if os.path.islink(full):
                continue
            files[rel] = sha256_of(full)
    return files


def main() -> int:
    if len(sys.argv) < 3:
        print('usage: integrity_sign.py <app_dir> <private_key_pem> [version]',
              file=sys.stderr)
        return 1
    app_dir, key_path = sys.argv[1], sys.argv[2]
    version = sys.argv[3] if len(sys.argv) > 3 else ''

    if not os.path.isfile(key_path):
        print('::warning::INTEGRITY_SIGN_KEY_PEM 未配置，跳过完整性清单签名',
              file=sys.stderr)
        return 2

    files = collect_files(app_dir)
    payload = json.dumps(
        {'version': version, 'files': files},
        ensure_ascii=False, sort_keys=True, separators=(',', ':'),
    ).encode('utf-8')

    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, 'payload.bin')
        sig = os.path.join(td, 'sig.bin')
        with open(src, 'wb') as f:
            f.write(payload)
        # Ed25519 要求 -rawin（对原始消息签名，OpenSSL 1.1.1+/3.x）
        r = subprocess.run([
            'openssl', 'pkeyutl', '-sign', '-inkey', key_path,
            '-rawin', '-in', src, '-out', sig,
        ], capture_output=True, text=True)
        if r.returncode != 0:
            print('::error::openssl 签名失败: ' + r.stderr, file=sys.stderr)
            return 1
        with open(sig, 'rb') as f:
            sig_bytes = f.read()

        # 自校验：用私钥自带公钥部分验一遍，防止私钥/流程配置错误产出废清单
        pub_check = subprocess.run([
            'openssl', 'pkeyutl', '-verify',
            '-inkey', key_path,
            '-rawin', '-sigfile', sig,
            '-in', src,
        ], capture_output=True, text=True)
        if pub_check.returncode != 0:
            print('::error::签名自校验失败: ' + pub_check.stderr,
                  file=sys.stderr)
            return 1

        manifest_path = os.path.join(app_dir, MANIFEST)
        with open(manifest_path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(MAGIC + '\n')
            f.write(base64.b64encode(sig_bytes).decode('ascii') + '\n')
            f.write(payload.decode('utf-8') + '\n')

    print(f'integrity.manifest 写入 {os.path.join(app_dir, MANIFEST)}: '
          f'{len(files)} 个文件, 签名 {len(sig_bytes)} 字节（自校验通过）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
