#!/usr/bin/env python3
"""Every Nyeko icon from one drawing of Nyo, rendered with rsvg-convert.

    python3 scripts/nyeko-icons.py            # needs rsvg-convert (librsvg) and Pillow

Nyo is drawn here in the units of his character sheet (120 × 120, head centre (60, 65)), the same numbers as the
painters in the apps (NotchBuddy/Sources/CoucouKit/NyoPainter.swift, windows/src/mochi/nyo.ts,
android/.../nyeko/NyoFace.kt). Writes:

- Mac: the app icon (NotchBuddy/Assets.xcassets/AppIcon.appiconset) and the menu bar template (MenuBarIcon.imageset);
- iPhone: NotchBuddy/PhoneAssets.xcassets (app icon, dark and tinted looks, coloured alternatives, previews);
- Windows/Linux: windows/src-tauri/icons (PNG sizes and icon.ico);
- Android: mipmap-xxxhdpi (launcher and adaptive foreground), the status-bar icon and the widget picker faces
  (vector drawables, res/drawable);
- web app: phone/web/icons (favicon.svg, 180, 192, 512).

© 2026 Rohil Sagar — Nyo and these icons are Nyeko's own (LICENSE-ASSETS.md).
"""
import io
import json
import os
import re
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INK, CREAM, FUR, PINK, NOSE = "#2B1D12", "#FFF6E9", "#FFE2BC", "#FF8FB1", "#FF6F91"
TAN, MINT = "#FF7A2F", "#2EC4B6"

HEAD = ("M60 30 C76 30 88 36 94 48 C98 56 99 63 98 69 L105 73 L97 77 L102 83 L93 85 C86 95 74 100 60 100 "
        "C46 100 34 95 27 85 L18 83 L23 77 L15 73 L22 69 C21 63 22 56 26 48 C32 36 44 30 60 30 Z")
EAR_L = "M31 50 C28 36 29 24 33 14 C42 19 50 27 55 37 Z"
EAR_R = "M89 50 C92 36 91 24 87 14 C78 19 70 27 65 37 Z"
INNER_L = "M35 42 C34 33 35 27 37 22 C42 26 46 31 48 36 Z"
INNER_R = "M85 42 C86 33 85 27 83 22 C78 26 74 31 72 36 Z"
TUFTS = "M33 15 L30 8 M33 15 L36 9 M87 15 L90 8 M87 15 L84 9"
STRIPES = "M53 35 L55 43 M60 33 L60 42 M67 35 L65 43"
WHISKERS = "M46 80 L30 78 M46 84 L31 87 M74 80 L90 78 M74 84 L89 87"
TAIL_REST = "M86 96 C104 98 114 88 112 74 C111 66 104 64 102 70"

# Nyo's face for icons: ears, head, muzzle, cheeks, stripes, mint eyes, nose, mouth, whiskers.
NYO = f"""
<path d="{EAR_L} {EAR_R}" fill="{FUR}" stroke="{INK}" stroke-width="3.5" stroke-linejoin="round"/>
<path d="{INNER_L} {INNER_R}" fill="{PINK}"/>
<path d="{TUFTS}" stroke="{INK}" stroke-width="2.2" stroke-linecap="round"/>
<path d="{HEAD}" fill="{FUR}" stroke="{INK}" stroke-width="3.5" stroke-linejoin="round"/>
<ellipse cx="60" cy="81" rx="16" ry="11" fill="{CREAM}"/>
<circle cx="31" cy="77" r="5" fill="{PINK}" opacity=".7"/><circle cx="89" cy="77" r="5" fill="{PINK}" opacity=".7"/>
<path d="{STRIPES}" stroke="{TAN}" stroke-width="3.4" stroke-linecap="round"/>
<circle cx="45" cy="64" r="9" fill="{MINT}" stroke="{INK}" stroke-width="2.8"/>
<circle cx="75" cy="64" r="9" fill="{MINT}" stroke="{INK}" stroke-width="2.8"/>
<ellipse cx="45" cy="64" rx="3.3" ry="6.4" fill="{INK}"/><ellipse cx="75" cy="64" rx="3.3" ry="6.4" fill="{INK}"/>
<circle cx="47.6" cy="60.8" r="2" fill="#FFFFFF"/><circle cx="77.6" cy="60.8" r="2" fill="#FFFFFF"/>
<path d="M56 75 L64 75 L60 79.5 Z" fill="{NOSE}" stroke="{INK}" stroke-width="1.6" stroke-linejoin="round"/>
<path d="M60 79.5 Q57 85 53 82.5 M60 79.5 Q63 85 67 82.5" fill="none" stroke="{INK}" stroke-width="2" stroke-linecap="round"/>
<path d="{WHISKERS}" stroke="{INK}" stroke-width="1.6" stroke-linecap="round"/>
"""
# The cream sticker edge around him, so he reads on any background.
STICKER = (f'<path d="{EAR_L} {EAR_R}" fill="{{c}}" stroke="{{c}}" stroke-width="14" stroke-linejoin="round"/>'
           f'<path d="{HEAD}" fill="{{c}}" stroke="{{c}}" stroke-width="14" stroke-linejoin="round"/>')
# His box in sheet units (ears' tufts to chin, fluff to fluff): centre (60, 54).
CX, CY = 60, 54

# The iPhone app's colours (its icon picker): name → background.
COLOURS = {"Orange": TAN, "Blue": "#3B9EFF", "Green": MINT, "Pink": PINK, "Purple": "#9B6BFF", "Graphite": "#5B5F66"}


def nyo_at(cx, cy, scale, edge=CREAM, nyo=NYO):
    tx, ty = cx - CX * scale, cy - CY * scale
    return f'<g transform="translate({tx:.2f} {ty:.2f}) scale({scale})">{STICKER.format(c=edge)}{nyo}</g>'


def square(bg, edge=CREAM, radius=0, size=1024, nyo=NYO):
    """Full-bleed icon (iOS, Android and the web round the corners themselves), Nyo centred."""
    back = f'<rect width="1024" height="1024" rx="{radius}" fill="{bg}"/>' if bg else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">{back}'
            f'{nyo_at(512, 520, 7.0, edge, nyo)}</svg>')


def tile(size=1024):
    """The rounded tangerine tile with an ink rim (Mac, Windows, the favicon): it carries its own shape."""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">'
            f'<rect x="100" y="100" width="824" height="824" rx="186" fill="{TAN}" stroke="{INK}" stroke-width="22"/>'
            f'{nyo_at(512, 528, 5.7)}</svg>')


def foreground(size=432):
    """Android adaptive foreground: Nyo inside the 66 dp safe circle of a 108 dp canvas, no background."""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 432 432">'
            f'{nyo_at(216, 222, 2.95)}</svg>')


def silhouette(fill="#000000"):
    """Head and ears in one colour, the eyes cut out (menu bar template, status bar)."""
    return (f'<path d="{HEAD} M54 64 a9 9 0 1 0 -18 0 a9 9 0 1 0 18 0 Z M84 64 a9 9 0 1 0 -18 0 a9 9 0 1 0 18 0 Z" '
            f'fill="{fill}" fill-rule="evenodd"/>'
            f'<path d="{EAR_L}" fill="{fill}"/><path d="{EAR_R}" fill="{fill}"/>')


def render(svg, out, size=None):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cmd = ["rsvg-convert", f.name, "-o", out]
    if size:
        cmd[1:1] = ["-w", str(size[0]), "-h", str(size[1])]
    subprocess.run(cmd, check=True)
    os.unlink(f.name)


def png_bytes(svg, w, h=None):
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "x.png")
        render(svg, out, (w, h or w))
        return open(out, "rb").read()


def tinted(path):
    """iOS tinted look: greyscale on black (the system adds the tint)."""
    from PIL import Image, ImageOps
    im = Image.open(path).convert("RGBA")
    grey = ImageOps.grayscale(im)
    black = Image.new("L", im.size, 0)
    black.paste(grey, mask=im.split()[3])
    black.save(path)


def opaque(path):
    """The web's apple-touch and PWA icons are opaque RGB."""
    from PIL import Image
    Image.open(path).convert("RGB").save(path)


def iphone():
    assets = os.path.join(ROOT, "NotchBuddy", "PhoneAssets.xcassets")
    render(square(COLOURS["Orange"]), os.path.join(assets, "AppIcon.appiconset", "icon-1024.png"))
    render(square("#1C1410"), os.path.join(assets, "AppIcon.appiconset", "icon-1024-dark.png"))
    t = os.path.join(assets, "AppIcon.appiconset", "icon-1024-tinted.png")
    render(square(None, edge="#FFFFFF"), t)
    tinted(t)
    for name, bg in COLOURS.items():
        if name != "Orange":
            render(square(bg), os.path.join(assets, f"AppIcon-{name}.appiconset", "icon-1024.png"))
        render(square(bg, radius=230, size=180), os.path.join(assets, f"IconPreview-{name}.imageset", "preview.png"))


def mac():
    icons = os.path.join(ROOT, "NotchBuddy", "Assets.xcassets", "AppIcon.appiconset")
    for base in (16, 32, 128, 256, 512):
        render(tile(), os.path.join(icons, f"icon_{base}x{base}.png"), (base, base))
        render(tile(), os.path.join(icons, f"icon_{base}x{base}@2x.png"), (base * 2, base * 2))
    # Menu bar: a template image (black and clear, macOS colours it), 24 × 18 pt.
    bar = os.path.join(ROOT, "NotchBuddy", "Assets.xcassets", "MenuBarIcon.imageset")
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="18" viewBox="1.35 12 117.3 88">'
           f'{silhouette()}</svg>')
    for scale, name in ((1, "menubar.png"), (2, "menubar@2x.png"), (3, "menubar@3x.png")):
        render(svg, os.path.join(bar, name), (24 * scale, 18 * scale))


def windows():
    from PIL import Image
    icons = os.path.join(ROOT, "windows", "src-tauri", "icons")
    for size, name in ((32, "32x32.png"), (128, "128x128.png"), (256, "128x128@2x.png"), (512, "icon.png")):
        render(tile(), os.path.join(icons, name), (size, size))
    sizes = [16, 24, 32, 48, 64, 128, 256]
    big = Image.open(io.BytesIO(png_bytes(tile(), 256))).convert("RGBA")
    big.save(os.path.join(icons, "icon.ico"), sizes=[(s, s) for s in sizes])


def android():
    res = os.path.join(ROOT, "android", "app", "src", "main", "res")
    render(square(TAN), os.path.join(res, "mipmap-xxxhdpi", "ic_launcher.png"), (512, 512))
    render(foreground(), os.path.join(res, "mipmap-xxxhdpi", "ic_launcher_foreground.png"), (432, 432))
    write_status_icon(os.path.join(res, "drawable", "ic_stat_mochi.xml"))
    for state in ("idle", "working", "waiting", "done"):
        write_widget_face(os.path.join(res, "drawable", f"preview_face_{state}.xml"), state)


def vpath(d):
    """SVG path data → Android pathData (commas between numbers, as the drawables write them)."""
    return re.sub(r"(-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?)", r"\1,\2", d)


def write_status_icon(path):
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<!-- One-colour Nyo for the status bar: his head with its cheek fluff and ears, the eyes cut out (scripts/nyeko-icons.py). -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp" android:viewportWidth="120" android:viewportHeight="120">
    <group android:translateY="3">
        <path android:fillColor="#FFFFFFFF" android:fillType="evenOdd"
            android:pathData="{vpath(HEAD)} M54,64 a9,9 0 1 0 -18,0 a9,9 0 1 0 18,0 Z M84,64 a9,9 0 1 0 -18,0 a9,9 0 1 0 18,0 Z" />
        <path android:fillColor="#FFFFFFFF" android:pathData="{vpath(EAR_L)}" />
        <path android:fillColor="#FFFFFFFF" android:pathData="{vpath(EAR_R)}" />
    </group>
</vector>
"""
    open(path, "w").write(xml)


def ellipse(cx, cy, rx, ry):
    return f"M{cx - rx},{cy} a{rx},{ry} 0 1 0 {2 * rx},0 a{rx},{ry} 0 1 0 {-2 * rx},0 Z"


def write_widget_face(path, state):
    """Nyo for the widget picker, in vectors (sharp at any density), keeping the state's badge from the file."""
    old = open(path).read() if os.path.exists(path) else ""
    lines = old.splitlines()
    # The badge: everything after the eyes (#1A1412) up to </vector>.
    last_eye = max((i for i, l in enumerate(lines) if "#1A1412" in l), default=None)
    badge = [l for l in lines[last_eye + 1:] if "</vector>" not in l] if last_eye is not None else []
    pupils = {"working": (2.5, 1, 1.9, 6.6), "waiting": (0, 0, 6, 6), "idle": (0, 0, 3.3, 6.4), "done": None}[state]
    tail = {"working": "M88 92 C106 88 112 70 106 52 C103 44 96 42 96 50",
            "waiting": "M88 92 C106 88 112 70 106 52 C103 44 96 42 96 50",
            "done": "M88 92 C108 90 114 70 104 58 C99 52 93 56 96 62", "idle": TAIL_REST}[state]
    a = 'android:'
    out = [
        '<?xml version="1.0" encoding="utf-8"?>',
        f'<!-- Nyo in the "{state}" state for the Widget picker (scripts/nyeko-icons.py): tail, ears, his fluffy head, stripes,',
        '     mint eyes, muzzle, whiskers, paws and the state badge. No bitmap, so it stays sharp at any density. -->',
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"',
        '    android:width="120dp"', '    android:height="120dp"',
        '    android:viewportWidth="120"', '    android:viewportHeight="120">',
        f'    <path {a}pathData="{vpath(EAR_L)} {vpath(EAR_R)}" {a}fillColor="{CREAM}" {a}strokeColor="{CREAM}" {a}strokeWidth="9" {a}strokeLineJoin="round" />',
        f'    <path {a}pathData="{vpath(HEAD)}" {a}fillColor="{CREAM}" {a}strokeColor="{CREAM}" {a}strokeWidth="9" {a}strokeLineJoin="round" />',
        f'    <path {a}pathData="{vpath(tail)}" {a}strokeColor="{INK}" {a}strokeWidth="14" {a}strokeLineCap="round" />',
        f'    <path {a}pathData="{vpath(tail)}" {a}strokeColor="{FUR}" {a}strokeWidth="9" {a}strokeLineCap="round" />',
        f'    <path {a}pathData="{vpath(tail)}" {a}strokeColor="{TAN}" {a}strokeWidth="9" {a}trimPathStart="0.64" {a}trimPathEnd="0.8" />',
        f'    <path {a}pathData="{vpath(EAR_L)} {vpath(EAR_R)}" {a}fillColor="{FUR}" {a}strokeColor="{INK}" {a}strokeWidth="3.5" {a}strokeLineJoin="round" />',
        f'    <path {a}pathData="{vpath(INNER_L)} {vpath(INNER_R)}" {a}fillColor="{PINK}" />',
        f'    <path {a}pathData="{vpath(HEAD)}" {a}fillColor="{FUR}" {a}strokeColor="{INK}" {a}strokeWidth="3.5" {a}strokeLineJoin="round" />',
        f'    <path {a}fillColor="{CREAM}" {a}pathData="{ellipse(60, 81, 16, 11)}" />',
        f'    <path {a}fillColor="#80FF8FB1" {a}pathData="{ellipse(31, 77, 5, 5)} {ellipse(89, 77, 5, 5)}" />',
        f'    <path {a}pathData="{vpath(STRIPES)}" {a}strokeColor="{TAN}" {a}strokeWidth="3.4" {a}strokeLineCap="round" />',
    ]
    if pupils is None:
        for cx in (45, 75):   # happy, closed eyes
            out.append(f'    <path {a}pathData="M{cx - 7},66 Q{cx},57 {cx + 7},66" {a}strokeColor="#1A1412" {a}strokeWidth="3.6" {a}strokeLineCap="round" />')
    else:
        dx, dy, prx, pry = pupils
        out.append(f'    <path {a}fillColor="{MINT}" {a}strokeColor="{INK}" {a}strokeWidth="2.8" {a}pathData="{ellipse(45, 64, 9, 9)} {ellipse(75, 64, 9, 9)}" />')
        for cx in (45, 75):
            out.append(f'    <path {a}fillColor="#1A1412" {a}pathData="{ellipse(cx + dx, 64 + dy, prx, pry)}" />')
        out.append(f'    <path {a}fillColor="#FFFFFF" {a}pathData="{ellipse(47.6 + dx, 60.8 + dy, 2, 2)} {ellipse(77.6 + dx, 60.8 + dy, 2, 2)}" />')
    out += [
        f'    <path {a}pathData="M56,75 L64,75 L60,79.5 Z" {a}fillColor="{NOSE}" {a}strokeColor="{INK}" {a}strokeWidth="1.6" {a}strokeLineJoin="round" />',
        (f'    <path {a}pathData="M54,81.5 Q60,90 66,81.5 Z" {a}fillColor="{NOSE}" {a}strokeColor="{INK}" {a}strokeWidth="2" {a}strokeLineJoin="round" />'
         if state == "done" else
         f'    <path {a}pathData="M60,79.5 Q57,85 53,82.5 M60,79.5 Q63,85 67,82.5" {a}strokeColor="{INK}" {a}strokeWidth="2" {a}strokeLineCap="round" />'),
        f'    <path {a}pathData="{vpath(WHISKERS)}" {a}strokeColor="{INK}" {a}strokeWidth="1.6" {a}strokeLineCap="round" />',
        f'    <path {a}fillColor="{FUR}" {a}strokeColor="{INK}" {a}strokeWidth="3" {a}pathData="{ellipse(46, 102, 9, 6)} {ellipse(74, 102, 9, 6)}" />',
    ]
    out += badge
    out.append("</vector>")
    open(path, "w").write("\n".join(out) + "\n")


def web():
    icons = os.path.join(ROOT, "phone", "web", "icons")
    for size in (180, 192, 512):
        p = os.path.join(icons, f"icon-{size}.png")
        render(square(TAN), p, (size, size))
        opaque(p)
    open(os.path.join(icons, "favicon.svg"), "w").write(tile() + "\n")


def main():
    iphone()
    mac()
    windows()
    android()
    web()
    print("Nyeko icons written (Mac, iPhone, Windows/Linux, Android, web).")


if __name__ == "__main__":
    main()
