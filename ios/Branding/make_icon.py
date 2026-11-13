"""Lumisound "sound eclipse" icon generator.

Writes icon.svg (full icon) plus the three tvOS parallax layers
(back = sky, middle = corona, front = disc + pulse + spark).
Render with: rsvg-convert -w 1024 -h 1024 icon.svg -o icon-1024.png
"""
import math, sys, os

W = H = 1024
CX, CY = 512, 520
R_DISC = 214
out = sys.argv[1] if len(sys.argv) > 1 else "."

DEFS = """
<defs>
  <radialGradient id="sky" cx="50%" cy="54%" r="72%">
    <stop offset="0" stop-color="#3a1580"/>
    <stop offset="0.45" stop-color="#160a3c"/>
    <stop offset="1" stop-color="#05030d"/>
  </radialGradient>
  <linearGradient id="aurora" gradientUnits="userSpaceOnUse" x1="200" y1="180" x2="840" y2="860">
    <stop offset="0" stop-color="#5ef2ff"/>
    <stop offset="0.5" stop-color="#ff5fd2"/>
    <stop offset="1" stop-color="#ffb84d"/>
  </linearGradient>
  <linearGradient id="pulse" gradientUnits="userSpaceOnUse" x1="330" y1="0" x2="700" y2="0">
    <stop offset="0" stop-color="#5ef2ff" stop-opacity="0.2"/>
    <stop offset="0.25" stop-color="#5ef2ff"/>
    <stop offset="0.6" stop-color="#ff5fd2"/>
    <stop offset="1" stop-color="#ffb84d" stop-opacity="0.25"/>
  </linearGradient>
  <radialGradient id="disc" cx="45%" cy="40%" r="70%">
    <stop offset="0" stop-color="#1b0f45"/>
    <stop offset="1" stop-color="#070418"/>
  </radialGradient>
  <filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
    <feGaussianBlur stdDeviation="18"/>
  </filter>
  <filter id="soft" x="-50%" y="-50%" width="200%" height="200%">
    <feGaussianBlur stdDeviation="6"/>
  </filter>
</defs>
"""

def rays():
    parts = []
    n = 96
    for i in range(n):
        a = i / n * 2 * math.pi - math.pi / 2
        # A waveform wrapped round the disc: two harmonics + a gentle beat.
        t = i / n * 2 * math.pi
        w = 0.55 + 0.28 * math.sin(t * 6) * math.cos(t * 2) + 0.17 * math.sin(t * 13 + 0.7)
        inner = R_DISC + 22
        outer = inner + 34 + 120 * max(0.08, w)
        x1, y1 = CX + math.cos(a) * inner, CY + math.sin(a) * inner
        x2, y2 = CX + math.cos(a) * outer, CY + math.sin(a) * outer
        parts.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" />')
    return "\n".join(parts)

def corona(blur):
    filt = ' filter="url(#glow)" opacity="0.85"' if blur else ''
    return f'<g stroke="url(#aurora)" stroke-width="13" stroke-linecap="round"{filt}>{rays()}</g>'

def pulse_path():
    pts = []
    x0, x1 = CX - R_DISC + 30, CX + R_DISC - 30
    steps = 160
    for k in range(steps + 1):
        x = x0 + (x1 - x0) * k / steps
        u = (x - CX) / (R_DISC - 30)
        env = math.cos(u * math.pi / 2) ** 2
        y = CY + 70 * env * math.sin(u * math.pi * 3.2) * (0.6 + 0.4 * math.cos(u * 7))
        pts.append(f"{x:.1f},{y:.1f}")
    return "M" + " L".join(pts)

def spark(x, y, s):
    return (f'<path d="M{x},{y-s} Q{x+s*0.18},{y-s*0.18} {x+s},{y} Q{x+s*0.18},{y+s*0.18} {x},{y+s} '
            f'Q{x-s*0.18},{y+s*0.18} {x-s},{y} Q{x-s*0.18},{y-s*0.18} {x},{y-s} Z" fill="#fff6e0"/>'
            f'<circle cx="{x}" cy="{y}" r="{s*0.55}" fill="#ffd27a" filter="url(#soft)" opacity="0.9"/>')

back = f'<rect width="{W}" height="{H}" fill="url(#sky)"/>'
# faint stars
import random
random.seed(7)
stars = "".join(f'<circle cx="{random.randint(20,1000)}" cy="{random.randint(20,1000)}" r="{random.choice([1.2,1.6,2.2])}" fill="#ffffff" opacity="{random.uniform(0.2,0.6):.2f}"/>' for _ in range(70))
middle = corona(True) + corona(False)
front = (f'<circle cx="{CX}" cy="{CY}" r="{R_DISC}" fill="url(#disc)"/>'
         f'<circle cx="{CX}" cy="{CY}" r="{R_DISC}" fill="none" stroke="url(#aurora)" stroke-width="5" opacity="0.9"/>'
         f'<path d="{pulse_path()}" fill="none" stroke="url(#pulse)" stroke-width="30" stroke-linecap="round" filter="url(#glow)" opacity="0.8"/>'
         f'<path d="{pulse_path()}" fill="none" stroke="url(#pulse)" stroke-width="16" stroke-linecap="round" stroke-linejoin="round"/>'
         + spark(CX + 228, CY - 236, 44))

def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">{DEFS}{body}</svg>'

os.makedirs(out, exist_ok=True)
open(os.path.join(out, "icon.svg"), "w").write(svg(back + stars + middle + front))
print("ok")

# ---- Composites for tvOS / watch -------------------------------------------
MARK = middle + front  # transparent: corona + disc + pulse + spark

def canvas(w, h, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
            f'{DEFS}{body}</svg>')

def placed(cx, cy, size):
    # The mark (with corona) spans ~840px of the 1024 artboard.
    s = size / 840
    return f'<g transform="translate({cx} {cy}) scale({s:.4f}) translate({-CX} {-CY})">{MARK}</g>'

def sky(w, h):
    random.seed(11)
    st = "".join(f'<circle cx="{random.uniform(0,w):.0f}" cy="{random.uniform(0,h):.0f}" r="{random.choice([1.2,1.6,2.2])}" fill="#fff" opacity="{random.uniform(0.2,0.6):.2f}"/>' for _ in range(int(w*h/14000)))
    return (f'<radialGradient id="tvsky" gradientUnits="userSpaceOnUse" cx="{w*0.5}" cy="{h*0.55}" r="{max(w,h)*0.62}">'
            f'<stop offset="0" stop-color="#3a1580"/><stop offset="0.45" stop-color="#160a3c"/><stop offset="1" stop-color="#05030d"/></radialGradient>'
            f'<rect width="{w}" height="{h}" fill="url(#tvsky)"/>{st}')

# tvOS app icon layers (1280x768 artboard, scaled down for 400x240 @1x/@2x).
open(os.path.join(out, "tv-back.svg"), "w").write(canvas(1280, 768, sky(1280, 768)))
open(os.path.join(out, "tv-front.svg"), "w").write(canvas(1280, 768, placed(640, 384, 700)))

def wordmark(x, y, size):
    return (f'<text x="{x}" y="{y}" font-family="Inter, Manrope, sans-serif" font-weight="700" font-size="{size}" '
            f'letter-spacing="{size*0.02:.1f}" fill="#ffffff">Lumisound</text>'
            f'<text x="{x+4}" y="{y+size*0.62:.0f}" font-family="Inter, Manrope, sans-serif" font-weight="500" '
            f'font-size="{size*0.30:.0f}" letter-spacing="{size*0.08:.1f}" fill="#c9b8ff" opacity="0.85">YOUR MUSIC, LIT UP</text>')

for name, w in (("tv-topshelf.svg", 1920), ("tv-topshelf-wide.svg", 2320)):
    body = sky(w, 720) + placed(w*0.30, 360, 600) + wordmark(w*0.30 + 380, 380, 132)
    open(os.path.join(out, name), "w").write(canvas(w, 720, body))
print("tv ok")
