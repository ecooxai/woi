#!/usr/bin/env python3
"""Click-accuracy test page for display :11.

A full-screen Tk canvas (override-redirect at +0+0, so canvas = screen
coordinates) that draws a fake app with targets of varied sizes at known
positions, writes them to <out>/layout<N>.json and logs every click
(x_root, y_root) to <out>/clicks.log.

  python3 targets.py --layout 0 --out DIR
"""
import argparse
import json
import random
import sys
import time
import tkinter as tk

ap = argparse.ArgumentParser()
ap.add_argument("--layout", type=int, default=0)
ap.add_argument("--out", required=True)
ap.add_argument("--w", type=int, default=1600)
ap.add_argument("--h", type=int, default=900)
ap.add_argument("--render-only", action="store_true")
a = ap.parse_args()

rnd = random.Random(1000 + a.layout)
from PIL import Image, ImageDraw, ImageFont

img = Image.new("RGB", (a.w, a.h), "#f4f5f7")
_d = ImageDraw.Draw(img)
_FONTS = {}


def _font(size, style):
    key = (size, style)
    if key not in _FONTS:
        name = {"bold": "DejaVuSans-Bold.ttf"}.get(style, "DejaVuSans.ttf")
        _FONTS[key] = ImageFont.truetype("/usr/share/fonts/TTF/" + name, int(size * 1.33))
    return _FONTS[key]


class _Canvas:
    """The few tk.Canvas calls used below, drawn with PIL (real TrueType fonts)."""

    def create_rectangle(self, x0, y0, x1, y1, fill=None, outline=None):
        _d.rectangle([x0, y0, x1, y1], fill=fill, outline=outline)

    def create_text(self, x, y, text="", anchor="center", fill="#000", font=None):
        _, size, *st = font
        style = st[0] if st else "normal"
        f = _font(size, "bold" if style == "bold" else "normal")
        _d.text((x, y), text, fill=fill, font=f, anchor="lm" if anchor == "w" else "mm")
        if style == "underline":
            l, t, r, b = _d.textbbox((x, y), text, font=f, anchor="lm" if anchor == "w" else "mm")
            _d.line([l, b + 1, r, b + 1], fill=fill)


c = _Canvas()
targets = []
F = "DejaVu Sans"


def add(tid, ask, x, y, w, h, kind):
    targets.append({"id": tid, "ask": ask, "x": x, "y": y, "w": w, "h": h, "kind": kind})


def button(tid, ask, x, y, w, h, label, fill="#ffffff", fg="#222", size=10, bold=False, outline="#9aa0a6"):
    c.create_rectangle(x, y, x + w, y + h, fill=fill, outline=outline)
    c.create_text(x + w / 2, y + h / 2, text=label, fill=fg, font=(F, size, "bold" if bold else "normal"))
    add(tid, ask, x, y, w, h, "button")


def icon(tid, ask, x, y, s, glyph, size=None):
    c.create_rectangle(x, y, x + s, y + s, fill="#ffffff", outline="#c4c7cc")
    c.create_text(x + s / 2, y + s / 2, text=glyph, fill="#333", font=(F, size or max(8, int(s * 0.5))))
    add(tid, ask, x, y, s, s, "icon")


# ---- layout knobs (vary per layout)
ox = rnd.randint(0, 120)            # app offset
oy = rnd.randint(0, 60)
isz = rnd.choice([22, 24, 26, 28])  # toolbar icon size
bh = rnd.choice([26, 30, 34])       # button height
side_w = rnd.randint(170, 230)

# window frame
W, H = a.w - ox - rnd.randint(0, 80), a.h - oy - rnd.randint(0, 40)
c.create_rectangle(ox, oy, ox + W, oy + H, fill="#ffffff", outline="#888")
# title bar
c.create_rectangle(ox, oy, ox + W, oy + 30, fill="#e8eaed", outline="#888")
c.create_text(ox + W / 2, oy + 15, text=["Mail – Woi test", "Project Tracker", "Settings Console"][a.layout % 3],
              font=(F, 10, "bold"))
icon("close", "the close (X) icon at the top right of the window title bar", ox + W - 28, oy + 4, 22, "✕", 10)
icon("maximize", "the maximize (square) icon in the window title bar", ox + W - 54, oy + 4, 22, "□", 11)
icon("minimize", "the minimize (_) icon in the window title bar", ox + W - 80, oy + 4, 22, "–", 11)

# toolbar
ty = oy + 40
glyphs = [("menu", "the hamburger menu icon (three lines) at the left of the toolbar", "☰"),
          ("back", "the back arrow icon in the toolbar", "←"),
          ("forward", "the forward arrow icon in the toolbar", "→"),
          ("reload", "the reload (circular arrow) icon in the toolbar", "⟳"),
          ("star", "the star icon in the toolbar", "★"),
          ("settings", "the gear (settings) icon in the toolbar", "⚙")]
rnd.shuffle(glyphs[3:])
tx = ox + 10
for gid, ask, g in glyphs[:5]:
    icon(gid, ask, tx, ty, isz, g)
    tx += isz + rnd.randint(6, 12)
# search field
sw = rnd.randint(260, 380)
sx = tx + 20
c.create_rectangle(sx, ty, sx + sw, ty + isz, fill="#ffffff", outline="#9aa0a6")
c.create_text(sx + 10, ty + isz / 2, text="Search…", anchor="w", fill="#888", font=(F, 10))
add("search", "the Search text field in the toolbar", sx, ty, sw, isz, "field")
gid, ask, g = glyphs[5]
icon(gid, ask, ox + W - 10 - isz, ty, isz, g)
icon("music", "the music note icon in the toolbar, left of the gear icon", ox + W - 20 - 2 * isz, ty, isz, "♫")

# sidebar
sy = ty + isz + 16
c.create_rectangle(ox, sy, ox + side_w, oy + H, fill="#f1f3f4", outline="#ddd")
folders = ["Inbox", "Drafts", "Sent", "Archive", "Spam", "Trash"]
rh = rnd.choice([26, 30, 36])
for i, f in enumerate(folders):
    y = sy + 10 + i * rh
    c.create_text(ox + 16, y + rh / 2, text=f, anchor="w", font=(F, 10))
    if f in ("Drafts", "Archive", "Trash"):
        add("folder_" + f.lower(), f"the {f} folder in the left sidebar", ox + 4, y, side_w - 8, rh, "row")
    if f == "Inbox":
        c.create_text(ox + side_w - 20, y + rh / 2, text="12", font=(F, 9, "bold"), fill="#1a73e8")

# main form
mx = ox + side_w + 40 + rnd.randint(0, 60)
my = sy + 20
c.create_text(mx, my, text="Account details", anchor="w", font=(F, 14, "bold"))
fw = rnd.randint(300, 420)
for i, (fid, lab) in enumerate([("name", "Name"), ("email", "Email")]):
    y = my + 40 + i * 56
    c.create_text(mx, y, text=lab, anchor="w", font=(F, 10))
    c.create_rectangle(mx, y + 12, mx + fw, y + 12 + 28, fill="#fff", outline="#9aa0a6")
    add(fid, f"the {lab} input field", mx, y + 12, fw, 28, "field")
cy = my + 40 + 2 * 56 + 6
c.create_rectangle(mx, cy, mx + 16, cy + 16, fill="#fff", outline="#555")
c.create_text(mx + 24, cy + 8, text="Remember me", anchor="w", font=(F, 10))
add("remember", "the 'Remember me' checkbox (the small box itself)", mx, cy, 16, 16, "checkbox")
c.create_rectangle(mx + 180, cy, mx + 196, cy + 16, fill="#fff", outline="#555")
c.create_text(mx + 204, cy + 8, text="Send newsletter", anchor="w", font=(F, 10))
add("newsletter", "the 'Send newsletter' checkbox (the small box itself)", mx + 180, cy, 16, 16, "checkbox")

by = cy + 40
bx = mx
for bid, lab, w, fill, fg in [("save", "Save", rnd.randint(70, 110), "#1a73e8", "#fff"),
                              ("cancel", "Cancel", rnd.randint(70, 100), "#fff", "#222"),
                              ("delete", "Delete account", rnd.randint(120, 150), "#fff", "#c5221f")]:
    button(bid, f"the {lab} button", bx, by, w, bh, lab, fill=fill, fg=fg)
    bx += w + rnd.randint(10, 20)
c.create_text(mx, by + bh + 24, text="Export as PDF", anchor="w", fill="#1a73e8", font=(F, 10, "underline"))
add("export", "the 'Export as PDF' link", mx, by + bh + 16, 100, 16, "link")

# pager (small number buttons)
py = by + bh + 60
px = mx
ps = rnd.choice([22, 24, 28])
for n in range(1, 8):
    icon(f"page{n}", f"the page number {n} button in the pager", px, py, ps, str(n), 9)
    px += ps + 4
for k in ("page1", "page2", "page4", "page6", "page7"):
    targets[:] = [t for t in targets if t["id"] != k]

# big call-to-action on the right
rx = ox + W - rnd.randint(300, 360)
ry = sy + rnd.randint(40, 200)
button("upgrade", "the big 'Upgrade to Pro' button", rx, ry, 240, 64, "Upgrade to Pro", fill="#188038", fg="#fff",
       size=14, bold=True)
# card with small actions
cy2 = ry + 110
c.create_rectangle(rx, cy2, rx + 260, cy2 + 120, fill="#fafafa", outline="#ccc")
c.create_text(rx + 12, cy2 + 16, text="Quarterly report.pdf", anchor="w", font=(F, 10, "bold"))
c.create_text(rx + 12, cy2 + 38, text="2.4 MB · edited yesterday", anchor="w", fill="#666", font=(F, 9))
button("download", "the Download button on the report card", rx + 12, cy2 + 70, 90, 28, "Download", size=9)
button("share", "the Share button on the report card", rx + 112, cy2 + 70, 70, 28, "Share", size=9)
icon("more", "the three-dots (more) icon on the report card", rx + 226, cy2 + 8, 24, "⋮", 12)

# status bar
sby = oy + H - 26
c.create_rectangle(ox, sby, ox + W, oy + H, fill="#e8eaed", outline="#888")
c.create_text(ox + side_w + 10, sby + 13, text="Connected · 3 unread", anchor="w", font=(F, 9))
icon("help", "the question mark (help) icon in the bottom status bar", ox + W - 30, sby + 3, 20, "?", 9)
icon("wifi", "the 'W' icon in the bottom status bar, left of the help icon", ox + W - 56, sby + 3, 20, "W", 9)

json.dump({"layout": a.layout, "screen": [a.w, a.h], "targets": targets},
          open(f"{a.out}/layout{a.layout}.json", "w"), indent=1)
img.save(f"{a.out}/page{a.layout}.png")
if a.render_only:
    sys.exit(0)
root = tk.Tk()
root.overrideredirect(True)
root.geometry(f"{a.w}x{a.h}+0+0")
photo = tk.PhotoImage(file=f"{a.out}/page{a.layout}.png")
cv = tk.Canvas(root, width=a.w, height=a.h, highlightthickness=0)
cv.create_image(0, 0, image=photo, anchor="nw")
cv.pack()
log = open(f"{a.out}/clicks.log", "a", buffering=1)


def on_click(e):
    log.write(f"{time.time():.3f} {e.x_root} {e.y_root} {e.num}\n")


cv.bind("<Button>", on_click)
print(f"layout {a.layout}: {len(targets)} targets", file=sys.stderr, flush=True)
root.mainloop()
