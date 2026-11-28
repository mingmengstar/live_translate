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

状态：PASS / FAIL / INCONCLUSIVE / STALE_WARN

* `PASS`（0）—— 全部命中，overlay_screen 确已进编译图
* `FAIL`（1）—— 源码里有但快照里没有 = 真回归，必须修代码
* `INCONCLUSIVE`（3）—— 对照组没命中，搜索方式本身不可信
* `STALE_WARN`（0）—— 只有清单过期（源码里也找不到那几条），
  代码没问题；会打印 GitHub warning，请顺手更新 REQUIRED

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
    # 必须带 U+2026 省略号：`main_screen.dart` 里有个几乎同形的
    # `等待语音输入...`（三个 ASCII 句点）。只写前六个字会命中那份文件，
    # 造成「修复前也 PASS」的假阳性。实测差异就在这个省略号上。
    ("等待语音输入\u2026", "overlay_screen 空状态文案"),
    # v0.9.2 新增的空状态副信息。选它的理由：整串是**纯字面量**，
    # 不含任何 `${}` 插值，AOT 里必然以完整常量存在；且只出现在
    # overlay_screen.dart（main_screen/home_screen 均无此文案），
    # 一旦 overlay_screen 被编译器跳过，这条会立刻 MISS。
    ("字幕条已就绪 · 播放任何声音就会出现在这里", "overlay_screen 空状态副信息"),
    ("到主界面点开始即可出字幕", "overlay_screen 空状态副信息（未运行分支）"),
    ("[Overlay] Lifecycle state", "overlay_screen.didChangeAppLifecycleState"),
    ("[Overlay] Data stream error", "overlay_screen.overlayListener.onError"),
]

# ⚠️ 这里曾经有一条 `调节透明度`。v0.9.2 把该 tooltip 改成了
# 「背景不透明度（当前 xx%）」——**带插值**，AOT 里会被拆成多个片段，
# 整串搜不到。CI 因此误报 FAIL（其余 7 条全 OK、overlayMain 也 OK，
# 说明 overlay_screen 确实进了快照，是判据失效而非回归）。
#
# 结论（新增判据时必须遵守）：
# 1. **只挑纯字面量**，绝不要拿含 `${}` 插值的 tooltip 当判据；
# 2. UI 文案改动时**同步改这份清单**，否则下次构建会以「假失败」方式报警。
#    改动前先在 lib/ui/overlay_screen.dart 里 grep 一遍字面量是否还在。

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


def check_literals_in_source(root: str) -> list[tuple[str, str]]:
    """检查每条 REQUIRED 判据在本地 lib/ 源码里是否还存在。

    为什么需要这一步
    ----------------
    AOT 校验的失败模式有两种，症状完全一样、结论完全相反：

    * **真回归**：源码里有这条字符串，但快照里没有 → overlay_screen
      没进编译图，必须修代码；
    * **判据过期**：源码里**已经没有**这条字符串（改了 UI 文案），
      快照里当然也没有 → 代码没问题，是这份清单该更新了。

    本轮的 FAIL 就是第二种：v0.9.2 把「调节透明度」改成了带插值的
    「背景不透明度（当前 xx%）」。若不区分，后续每次 UI 改文案都会
    以「overlay_screen 仍未真正进入 AOT 快照」的红色报错呈现，
    让人误以为编译图又断了 —— 比不校验更浪费时间。

    返回「在源码里找不到」的判据列表；非空即判 STALE（退出码 4）。
    """
    if not root or not os.path.isdir(root):
        return []

    blobs = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(".dart"):
                continue
            try:
                with open(os.path.join(dirpath, fn), "r", encoding="utf-8") as f:
                    blobs.append(f.read())
            except (OSError, UnicodeDecodeError):
                continue
    if not blobs:
        return []

    haystack = "\n".join(blobs)
    stale = []
    for text, origin in REQUIRED:
        if text not in haystack:
            stale.append((text, origin))
    return stale


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
    ap.add_argument(
        "--src-root",
        default=None,
        help="用于「判据过期」自检的 Dart 源码根目录（通常传 lib）。不传则跳过自检",
    )
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
        # 先分清是「真回归」还是「判据过期」——两者的处置完全相反，
        # 混在一起报会让下一次 UI 改文案又变成一次红色构建。
        stale = check_literals_in_source(args.src_root or "") if args.src_root else []
        stale_texts = {t for t, _ in stale}

        if args.src_root and missing and all(m in stale_texts for m in missing):
            # GitHub Actions 注解：让这条警告直接出现在 CI 页面顶部，
            # 而不是埋在 300 行日志里（本轮就是日志里翻出来的）。
            joined = ", ".join(repr(t) for t in missing)
            print(
                f"::warning title=AOT 判据过期::{len(missing)} 条 REQUIRED "
                f"在当前源码里已不存在（{joined}），请更新 "
                f"tools/verify_overlay_aot.py。本次不拦构建。"
            )
            print(f"STALE: {len(missing)} 条判据在**当前源码里也不存在**：")
            for t in missing:
                print(f"       {t!r}")
            print("      → 不是回归。UI 文案改过了，是 REQUIRED 清单过期。")
            print("      → 请把 tools/verify_overlay_aot.py 的 REQUIRED 换成")
            print("        overlay_screen.dart 里**当前存在的纯字面量**（不要带 ${} 插值）。")
            # ## 返回 0 而不是非 0（v0.9.3 修正）
            #
            # 这个门禁的目的是「发现 overlay_screen 被踢出编译图」。
            # 既然 REQUIRED 里剩下的判据全部命中、且 overlayMain 也在，
            # 编译图本身就是好的 —— 只有清单里那几条无效判据在报错。
            #
            # 若在此处 return 1，一次 UI 文案改动就会拦下整个 APK，
            # 代价远大于收益（本轮 v0.9.2 就是这么被误拦的）。
            # 所以降级为「带 GitHub 警告标注的通过」，并要求同步更新清单。
            print("RESULT=STALE_WARN")
            return 0

        print(f"FAIL: 仍有 {len(missing)} 条 overlay_screen 字符串不在 libapp.so 里")
        print("      → overlay_screen.dart 仍未真正进入 AOT 快照")
        if stale:
            print(f"      注：其中 {len(stale)} 条在当前源码里也不存在，")
            print("          那几条属于清单过期，需同时更新 REQUIRED。")
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
