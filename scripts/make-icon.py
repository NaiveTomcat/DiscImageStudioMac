#!/usr/bin/env python3
"""生成 AppIcon.icns（纯程序化，不依赖任何外部素材）。

设计：深蓝圆角方块 + 一张「盘面」——同心圆环带彩色渐变，叠加细密螺旋纹
（模拟记录轨道），中心留出夹持孔；左上角一道高光表示塑料盘基反射。

用法：
    python3 scripts/make-icon.py [输出目录]

输出：
    <目录>/AppIcon.iconset/   （iconutil 的输入）
    <目录>/AppIcon.icns      （最终图标）
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# 先在 2048 上画，再 LANCZOS 降到 1024，等于 2× 超采样抗锯齿。
SUPERSAMPLE = 2048
FINAL = 1024

# 盘面配色：青 → 蓝紫 → 琥珀，沿半径插值，读起来像「把一张照片烧进了盘」
PALETTE = np.array([
    [ 34, 211, 238],   # cyan-400
    [ 56, 132, 255],   # blue
    [139,  92, 246],   # violet-500
    [236,  72, 153],   # pink-500
    [245, 158,  11],   # amber-500
], dtype=np.float64)

BACKGROUND_TOP = np.array([14, 22, 38], dtype=np.float64)
BACKGROUND_BOTTOM = np.array([24, 38, 64], dtype=np.float64)


def rounded_square_mask(size: int, corner_ratio: float = 0.2237) -> np.ndarray:
    """macOS 图标的标准圆角方块遮罩（圆角半径约为边长的 22.37%）。"""
    radius = size * corner_ratio
    center = size / 2.0
    half = size / 2.0 - radius
    coords = np.arange(size, dtype=np.float64) + 0.5 - center
    dx = np.abs(coords)[None, :] - half
    dy = np.abs(coords)[:, None] - half
    dx = np.clip(dx, 0, None)
    dy = np.clip(dy, 0, None)
    distance = np.sqrt(dx * dx + dy * dy)
    mask = np.clip(radius - distance + 0.5, 0, 1)
    return mask


def render_supersampled() -> np.ndarray:
    size = SUPERSAMPLE
    coords = np.arange(size, dtype=np.float64) + 0.5
    x = coords[None, :] - size / 2.0
    y = coords[:, None] - size / 2.0
    radius = np.sqrt(x * x + y * y)
    angle = np.arctan2(y, x)

    # 背景：上下渐变 + 圆角遮罩
    vertical = (coords / size)[:, None]
    background = BACKGROUND_TOP[None, None, :] * (1 - vertical[..., None]) \
        + BACKGROUND_BOTTOM[None, None, :] * vertical[..., None]
    background = np.broadcast_to(background, (size, size, 3)).copy()

    # 盘面半径（相对图标边长）
    outer = size * 0.372
    inner = size * 0.086
    disc_mask = np.clip(outer - radius + 0.75, 0, 1) * np.clip(radius - inner + 0.75, 0, 1)
    disc_mask = np.clip(disc_mask, 0, 1)

    # 沿半径的调色板插值
    t = np.clip((radius - inner) / (outer - inner), 0, 1)
    position = t * (len(PALETTE) - 1)
    lower = np.floor(position).astype(int)
    upper = np.minimum(lower + 1, len(PALETTE) - 1)
    frac = (position - lower)[..., None]
    disc_color = PALETTE[lower] * (1 - frac) + PALETTE[upper] * frac

    # 叠一层极轻的角向明暗，让环带看起来是「转动的」而不是纯同心圆
    disc_color *= (0.92 + 0.08 * np.cos(2 * angle))[..., None]

    # 螺旋轨道纹：沿半径高频起伏，被角度缓慢调制，形成细密螺旋
    tracks = np.sin((radius / size * 520.0) - angle * 3.0)
    disc_color *= (1.0 + 0.045 * tracks)[..., None]

    # 外缘暗角 + 内缘阴影，增加厚度感
    edge = np.clip((outer - radius) / (size * 0.02), 0, 1)
    disc_color *= (0.72 + 0.28 * edge)[..., None]
    rim = np.exp(-((radius - outer) ** 2) / (2 * (size * 0.0035) ** 2))
    disc_color = disc_color * (1 - 0.35 * rim[..., None]) + 0.35 * rim[..., None] * np.array([255, 255, 255])

    # 左上高光（塑料盘基反射）
    highlight = np.exp(-(((x + size * 0.20) ** 2 + (y + size * 0.24) ** 2) / (2 * (size * 0.26) ** 2)))
    disc_color = np.clip(disc_color + 52 * highlight[..., None] * disc_mask[..., None], 0, 255)

    # 夹持孔：挖回背景色，再补一圈内壁高光
    hole = np.clip(inner - radius + 0.75, 0, 1)
    hole_color = BACKGROUND_TOP * 0.55
    hole_wall = np.exp(-((radius - inner) ** 2) / (2 * (size * 0.006) ** 2))
    disc_color = disc_color * (1 - hole[..., None]) + hole_color[None, None, :] * hole[..., None]
    disc_color = np.clip(disc_color + 90 * hole_wall[..., None], 0, 255)

    canvas = background * (1 - disc_mask[..., None]) + disc_color * disc_mask[..., None]

    # 图标投影：在圆角方块外侧加一点柔和暗边，贴到浅色背景上不糊
    mask = rounded_square_mask(size)
    canvas = canvas * mask[..., None]
    return np.clip(canvas, 0, 255).astype(np.uint8)


def main() -> int:
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("dist")
    output.mkdir(parents=True, exist_ok=True)

    print("[icon] 渲染 2048×2048 并降采样到 1024×1024 …", file=sys.stderr)
    image = Image.fromarray(render_supersampled(), mode="RGB")
    icon_1024 = image.resize((FINAL, FINAL), Image.LANCZOS)

    master = output / "AppIcon-1024.png"
    icon_1024.save(master)

    iconset = output / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True)

    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            resized = icon_1024.resize((pixels, pixels), Image.LANCZOS)
            resized.save(iconset / name)

    icns = output / "AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
    print(f"[icon] 完成：{icns}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
