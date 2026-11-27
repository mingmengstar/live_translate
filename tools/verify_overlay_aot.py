#!/usr/bin/env python3
"""产物级校验：overlayMain 是否真的进了 libapp.so

为什么需要这个脚本
------------------
`flutter build apk --release` 成功 **不代表** 悬浮窗能显示。
v0.3.4 的事故就是：构建绿、单测全过、OverlayService 也起来了，
但 libapp.so 里根本没有 overlay_screen.dart 的任何字节 ——
因为没人 import 它，编译器按 import 图把它整份跳过了。

`@pragma('vm:entry-point')` 只能保住「已进编译图」的函数，救不回
一份未参与编译的文件。而原生侧是按字符串名字找入口点的：

    new DartEntrypoint(bundlePath, "overlayMain")

结论：唯一可信的验证方式是打开 APK，从 libapp.so 里把字符串捞出来看。

匹配方式
--------
Dart AOT 快照里的字符串常量是 **UTF-16LE** 存的，直接按 ASCII/UTF-8
搜会全部落空。因此这里用 utf-16-le 编码后再搜。

同时必须带对照组：只搜「期望命中」的字符串，如果整个匹配逻辑写错了
（比如编码搞错），会误判成「仍未修复」。所以每组都配一条
「已知一定存在」的对照字符串，对照组不命中就说明脚本本身有问题。

状态：PASS / FAIL / INCONCLUSIVE（脚本没能自证，不能算失败也不能算通过）

用法
----
    python3 tools/verify_overlay_aot.py app-arm64-v8a-release.apk
    python3 tools/verify_overlay_aot.py app-arm64-v8a-release.apk --lib path/to/libapp.so
"""

import argparse
import os
import sys
import zipfile

LIB_PATH_IN_APK = "lib/arm64-v8a/libapp.so"

# 必须命中：全部来自 lib/ui/overlay_screen.dart。
# 每条都单独列出来是为了失败时能立刻看出「哪一段被砍了」。
REQUIRED = [
    ("[Overlay] Initialized and listening for data", "overlay_screen._initializeOverlay"),
    ("[Overlay] Lifecycle state", "overlay_screen.didChangeAppLifecycleState"),
    ("实时翻译 - 悬浮窗", "overlay_screen.OverlayApp.title"),
    ("减小字号", "overlay_screen 控制栏 tooltip"),
    ("调节透明度", "overlay_screen 控制栏 tooltip"),
    ("等待语音输入", "overlay_screen 空状态文案"),
]

# 对照组：这些必须存在，用于证明「字符串确实在 libapp.so 里、编码没搞错」。
# 若对照组缺失，本脚本的结论不可信，应当报 INCONCLUSIVE 而不是 FAIL。
CONTROL = [
    ("实时翻译正在运行", "overlay_controller.showOverlay(overlayTitle:)"),
    ("正在初始化引擎...", "main.dart _LoadingScreen"),
]


def load_libapp(apk_path: str, lib_override: str | None) -> bytes:
    if lib_override:
        with open(lib_override, "rb") as f:
            return f.read()
    with zipfile.ZipFile(apk_path) as z:
        names = z.namelist()
        if LIB_PATH_IN_APK not in names:
            candidates = [n for n in names if n.endswith("libapp.so")]
            raise SystemExit(
                f"找不到 {LIB_PATH_IN_APK}\n"
                f"APK 里的 libapp.so: {candidates or '(一个都没有)'}"
            )
        return z.read(LIB_PATH_IN_APK)


def probe(blob: bytes, text: str) -> bool:
    """按 UTF-16LE 搜索（AOT 快照里字符串的真实编码）。"""
    return blob.find(text.encode("utf-16-le")) != -1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("apk", help="release APK 路径")
    ap.add_argument("--lib", default=None, help="直接给一个已解压的 libapp.so")
    args = ap.parse_args()

    if not args.lib and not os.path.isfile(args.apk):
        print(f"APK 不存在: {args.apk}", file=sys.stderr)
        return 2

    blob = load_libapp(args.apk, args.lib)
    print(f"libapp.so 大小: {len(blob):,} bytes\n")

    print("=== 对照组（必须存在，否则脚本结论不可信）===")
    control_ok = True
    for text, origin in CONTROL:
        hit = probe(blob, text)
        print(f"  [{'OK' if hit else 'MISS'}] {text!r}  <- {origin}")
        if not hit:
            control_ok = False

    if not control_ok:
        print(
            "\n对照组未命中：说明匹配方式有问题（编码/文件选错），"
            "本脚本无法判断 overlayMain 是否已修复。"
        )
        print("RESULT=INCONCLUSIVE")
        return 3

    print("\n=== 目标字符串（来自 overlay_screen.dart）===")
    missing = []
    for text, origin in REQUIRED:
        hit = probe(blob, text)
        print(f"  [{'OK' if hit else 'MISS'}] {text!r}  <- {origin}")
        if not hit:
            missing.append(text)

    print()
    if missing:
        print(f"FAIL: 仍有 {len(missing)} 条 overlay_screen 字符串不在 libapp.so 里")
        print("      → overlay_screen.dart 仍未真正进入 AOT 快照")
        print("RESULT=FAIL")
        return 1

    print("PASS: overlay_screen.dart 已完整进入 libapp.so，overlayMain 可被运行时解析")
    print("RESULT=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
