#!/usr/bin/env python3

"""从定版品牌资产生成 App 图标全套尺寸与 .icns。

资产源：Resources/AppIcon-source.png（八角线描、白底、圆角方形，1024×1024，
线条为图谱蓝 #25A1E0 系，2026-11-12 用户定版）。历史版本曾用程序化绘制
荧光绿渐变图标，已随「图谱蓝线描」换装退役——本脚本只做缩放，不再绘制。

源图圆角矩形几乎撑满画布，直接出 icns 在 Dock 里比别的 App 大一圈；
本脚本先按 macOS 画布规范（1024 画布里图标本体约 824，每边留 100）
等比缩小并居中，再生成各尺寸。

用法：python3 scripts/make_icon.py
产出：work/AppIcon.iconset/、Resources/AppIcon.icns 与同源预览
Resources/AppIcon-1024.png（成品，勿当作源图再喂回本脚本）。
"""

from pathlib import Path
import shutil
import subprocess

from PIL import Image


ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
# 原始资产固定不改（重复运行不会越缩越小）。
SOURCE = RESOURCES / "AppIcon-source.png"
ICONSET = ROOT / "work" / "AppIcon.iconset"
ICNS = RESOURCES / "AppIcon.icns"

POINT_SIZES = (16, 32, 128, 256, 512)


# macOS 图标画布留白规范：1024 画布里圆角矩形本体约占 824（每边留 100）。
# 源图圆角矩形几乎撑满画布，直接出 icns 在 Dock 里会比别的 App 大一圈，
# 因此生成前先等比缩到 824 并居中，放回 1024 透明画布。
CANVAS = 1024
BODY = 824


def fitted_icon(source: Image.Image) -> Image.Image:
    """把源图缩到 BODY 尺寸并居中放到 CANVAS 透明画布上。"""
    fitted = source.resize((BODY, BODY), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    canvas.alpha_composite(fitted, (offset, offset))
    return canvas


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"缺少图标资产：{SOURCE}")

    source = Image.open(SOURCE).convert("RGBA")
    if source.size != (CANVAS, CANVAS):
        raise SystemExit(f"图标资产须为 1024×1024，当前 {source.size}")

    icon = fitted_icon(source)

    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True, exist_ok=True)

    for point_size in POINT_SIZES:
        icon.resize(
            (point_size, point_size),
            Image.Resampling.LANCZOS,
        ).save(ICONSET / f"icon_{point_size}x{point_size}.png")
        icon.resize(
            (point_size * 2, point_size * 2),
            Image.Resampling.LANCZOS,
        ).save(ICONSET / f"icon_{point_size}x{point_size}@2x.png")

    subprocess.run(
        ["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)],
        check=True,
    )
    # 同步更新 1024 预览图（与 icns 同源，避免两处不一致）
    icon.save(RESOURCES / "AppIcon-1024.png")
    print(f"{ICONSET}\n{ICNS}")


if __name__ == "__main__":
    main()
