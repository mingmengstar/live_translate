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

匹配方式（这里有个致命细节，改前必读）
------------------------------------
Dart AOT 会把字符串常量按内容分成两种编码存进快照：

* **纯 ASCII**（整串都在 0x00-0x7F，如 `[Overlay] Lifecycle state`）
  → 存成 **Latin-1 单字节**
* **含非 ASCII**（如 `实时翻译 - 悬浮窗`）
  → 存成 **UTF-16LE**

这是 Dart VM 的 one-byte string 优化。所以「只用 utf-16-le 搜」
会让所有纯 ASCII 字符串**恒定 miss** —— 那是假阴性，不是证据。

历史教训：v0.3.4 的交接文档正是用 `utf-16-le` 去搜
`[Overlay] Lifecycle state`（纯 ASCII），得到「缺失」结论。该条
判据本身无效；真正有效的证据是同批中文串（`减小字号` 等）确实
不在。到 v0.3.5 修复后，中文串全部命中 —— 那才是可采信的对比。

因此本脚本对每条字符串**两种编码都试**，任一命中即视为存在。
风险：ASCII 串按 latin-1 搜可能撞上别处的巧合字节。所以下面的
REQUIRED 以中文串为主（编码唯一、不会误撞），ASCII 串只作补充。

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
#
# 以**中文串**为主：它们编码唯一（UTF-16LE），不会撞上别处的巧合字节，
# 是真正可信的证据。ASCII 串只作补充，命中说明「有这个符号」，
# 但不适合单独作为「已修复」的结论依据。
REQUIRED = [
    ("实时翻译 - 悬浮窗", "overlay_screen.OverlayApp.title"),
    ("减小字号", "overlay_screen 控制栏 tooltip"),
    ("增大字号", "overlay_screen 控制栏 tooltip"),
    ("调节透明度", "overlay_screen 控制栏 tooltip"),
    # 必须带 U+2026 省略号：`main_screen.dart` 里有个几乎同形的
    # `等待语音输入...`（三个 ASCII 句点）。只写前六个字会命中那份文件，
    # 造成「修复前也 PASS」的假阳性。实测差异就在这个省略号上。
    ("等待语音输入\u2026", "overlay_screen 空状态文案"),
    ("[Overlay] Lifecycle state", "overlay_screen.didChangeAppLifecycleState"),
    ("[Overlay] Data stream error", "overlay_screen.overlayListener.onError"),
]

# 入口点符号表：这是最直接的判据。
#
# 原生侧按字符串名字注册/查找入口点，这个名字必须真的出现在快照的
# 入口点符号表里。实测 v0.3.4 完全没有这个符号，v0.3.5 有了。
ENTRYPOINT_SYMBOL = "overlayMain"

# 负对照：这些**不应该**出现在快照里。
#
# 它们都是历史上被删掉的假实现/死代码的符号。如果又出现，说明有人
# 把它们恢复回来了（比如把「点了没反应」的占位 handler 加回去装样子）。
#
# ⚠️ 必须带边界匹配，不能用裸子串 —— 这里踩过一次坑：
# Flutter 框架自身有 `_updateOpacity`（在
# `_CupertinoTextSelectionToolbarShape` 里）和 `_updatePosition`
# （在 `SelectionRect` 附近）。用裸 `updateOpacity` 去搜会命中框架符号，
# 误报成「死代码被恢复了」。这跟前面 utf-16le 的假阴性一样，
# 都是「验证方法本身出错」，比 bug 更浪费时间。
#
# 规则：命中位置的前一个字节不能是标识符字符。
FORBIDDEN = [
    ("updateFontSize", "已删除的 OverlayFlutterEngine 占位 handler"),
    ("updateOpacity", "已删除的 OverlayFlutterEngine 占位 handler"),
    ("updatePosition", "已删除的 OverlayFlutterEngine 占位 handler"),
    ("OverlayFlutterEngine", "已删除的死代码 Service"),
    ("live_translate/overlay", "已删除的死通道"),
]

_IDENT = set(
    b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$"
)

# 对照组：这些必须存在，用于证明「文件选对了、搜索逻辑没坏」。
# 若对照组缺失，本脚本的结论不可信，应报 INCONCLUSIVE 而不是 FAIL。
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


def probe(blob: bytes, text: str) -> tuple[bool, str]:
    """在 AOT 快照里找字符串，返回 (是否命中, 命中的编码)。

    Dart VM 对「全是 ASCII 的字符串」用 one-byte (Latin-1) 存储，
    对含非 ASCII 的字符串用 TwoByte (UTF-16LE) 存储。所以必须两种都试，
    否则纯 ASCII 串会恒 miss（v0.3.4 的判据就是这么失效的）。
    """
    if blob.find(text.encode("utf-16-le")) != -1:
        return True, "utf-16le"
    try:
        if blob.find(text.encode("latin-1")) != -1:
            return True, "latin-1"
    except UnicodeEncodeError:
        # 含非 ASCII 字符，不可能以 latin-1 单字节形式存在
        pass
    return False, ""


def find_token(blob: bytes, text: str) -> int:
    """查找一个「完整标识符」，返回首次命中位置（-1 表示没有）。

    和 `probe()` 的区别：这里要求命中位置的**前一个字节不是标识符字符**。
    例如搜 `updateOpacity` 时不能命中 Flutter 框架的 `_updateOpacity`。
    """
    needle = text.encode("latin-1")
    start = 0
    while True:
        i = blob.find(needle, start)
        if i == -1:
            return -1
        if i == 0 or blob[i - 1] not in _IDENT:
            return i
        start = i + 1


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
        hit, enc = probe(blob, text)
        print(f"  [{'OK  ' + enc if hit else 'MISS':8}] {text!r}  <- {origin}")
        if not hit:
            control_ok = False

    if not control_ok:
        print(
            "\n对照组未命中：说明匹配方式有问题（编码/文件选错），"
            "本脚本无法判断 overlayMain 是否已修复。"
        )
        print("RESULT=INCONCLUSIVE")
        return 3

    print("\n=== 入口点符号表 ===")
    # 对照组同时提供「main 必然存在」的基线，说明符号表的搜索方式是对的。
    main_hit, _ = probe(blob, "main")
    print(f"  [{'OK' if main_hit else 'MISS'}] {'main'!r}  <- 基线（对照组）")
    ep_hit, ep_enc = probe(blob, ENTRYPOINT_SYMBOL)
    print(f"  [{'OK  ' + ep_enc if ep_hit else 'MISS':8}] {ENTRYPOINT_SYMBOL!r}  <- 悬浮窗入口点")
    if not main_hit:
        print("\n连 'main' 都找不到，符号表搜索方式不可靠。")
        print("RESULT=INCONCLUSIVE")
        return 3
    if not ep_hit:
        print("\nFAIL: 入口点符号 overlayMain 不在快照里，原生侧按名字查不到它。")
        print("RESULT=FAIL")
        return 1

    print("\n=== 目标字符串（来自 overlay_screen.dart）===")
    missing = []
    for text, origin in REQUIRED:
        hit, enc = probe(blob, text)
        print(f"  [{'OK  ' + enc if hit else 'MISS':8}] {text!r}  <- {origin}")
        if not hit:
            missing.append(text)

    print()
    if missing:
        print(f"FAIL: 仍有 {len(missing)} 条 overlay_screen 字符串不在 libapp.so 里")
        print("      → overlay_screen.dart 仍未真正进入 AOT 快照")
        print("RESULT=FAIL")
        return 1

    # 负对照：确认死代码没有被偷偷恢复
    print("=== 负对照（已删除的假实现不得回归）===")
    resurrected = []
    for symbol, what in FORBIDDEN:
        pos = find_token(blob, symbol)
        if pos == -1:
            print(f"  [OK      ] {symbol!r:24} <- {what}")
        else:
            print(f"  [HIT!    ] {symbol!r:24} <- {what}")
            resurrected.append(symbol)

    if resurrected:
        print(
            f"\nFAIL: {len(resurrected)} 个已删除的符号又出现了：{resurrected}\n"
            "      这些 handler 当年全是 result.success(true) 占位、"
            "点了没反应，不要恢复。"
        )
        print("RESULT=FAIL")
        return 1

    print()
    print("PASS: overlay_screen.dart 已完整进入 libapp.so，overlayMain 可被运行时解析")
    print("RESULT=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
