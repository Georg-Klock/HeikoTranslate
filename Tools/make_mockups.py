"""Compose iPhone device mockups for the Heiko Translate case study."""
from PIL import Image, ImageDraw, ImageFilter
import math

BG_TOP = (13, 14, 17)
BG_BOTTOM = (7, 7, 9)


def rounded_mask(size, radius, supersample=4):
    w, h = size
    m = Image.new("L", (w * supersample, h * supersample), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, w * supersample - 1, h * supersample - 1],
        radius=radius * supersample, fill=255)
    return m.resize(size, Image.LANCZOS)


def frame_phone(shot, screen_w):
    """Return an RGBA phone: screenshot inside a titanium-ish bezel."""
    ratio = shot.height / shot.width
    screen_h = int(round(screen_w * ratio))
    screen = shot.convert("RGB").resize((screen_w, screen_h), Image.LANCZOS)

    scr_r = int(screen_w * 0.095)          # screen corner radius
    bezel = max(3, int(screen_w * 0.021))  # black bezel around the glass
    rim = max(2, int(screen_w * 0.011))    # metal rim outside the bezel

    body_w = screen_w + 2 * (bezel + rim)
    body_h = screen_h + 2 * (bezel + rim)
    body_r = scr_r + bezel + rim

    phone = Image.new("RGBA", (body_w, body_h), (0, 0, 0, 0))

    # Metal rim: vertical gradient so the edge catches light.
    rim_img = Image.new("RGB", (body_w, body_h))
    rd = ImageDraw.Draw(rim_img)
    for y in range(body_h):
        t = y / max(1, body_h - 1)
        shade = 0.5 + 0.5 * math.sin(math.pi * t)      # bright at the middle
        edge = 118 + int(70 * shade)
        rd.line([(0, y), (body_w, y)], fill=(edge, edge - 4, edge - 10))
    phone.paste(rim_img, (0, 0), rounded_mask((body_w, body_h), body_r))

    # Black bezel.
    bz_w, bz_h = screen_w + 2 * bezel, screen_h + 2 * bezel
    bezel_img = Image.new("RGB", (bz_w, bz_h), (8, 8, 10))
    phone.paste(bezel_img, (rim, rim), rounded_mask((bz_w, bz_h), scr_r + bezel))

    # Screen.
    phone.paste(screen, (rim + bezel, rim + bezel),
                rounded_mask((screen_w, screen_h), scr_r))
    return phone


def drop_shadow(phone, blur=38, dy=26, opacity=150):
    pad = blur * 3
    sh = Image.new("RGBA", (phone.width + pad * 2, phone.height + pad * 2), (0, 0, 0, 0))
    solid = Image.new("RGBA", phone.size, (0, 0, 0, opacity))
    sh.paste(solid, (pad, pad + dy), phone.split()[3])
    return sh.filter(ImageFilter.GaussianBlur(blur)), pad


def canvas(w, h):
    bg = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(bg)
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3))
        d.line([(0, y), (w, y)], fill=c)
    # Soft glow behind the subject so the phone separates from the page black.
    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).ellipse(
        [w * 0.16, h * 0.02, w * 0.84, h * 1.05], fill=64)
    glow = glow.filter(ImageFilter.GaussianBlur(w // 9))
    bg.paste(Image.new("RGB", (w, h), (56, 60, 72)), (0, 0), glow)
    return bg


def place(bg, phone, cx, cy):
    sh, pad = drop_shadow(phone)
    bg.paste(sh, (int(cx - phone.width / 2) - pad, int(cy - phone.height / 2) - pad), sh)
    bg.paste(phone, (int(cx - phone.width / 2), int(cy - phone.height / 2)), phone)


def single(shot_path, out, w=2400, h=1350, screen_w=None, cy_bias=0.5):
    bg = canvas(w, h)
    shot = Image.open(shot_path)
    screen_w = screen_w or int(w * 0.20)
    phone = frame_phone(shot, screen_w)
    place(bg, phone, w // 2, int(h * cy_bias))
    bg.save(out, quality=94)
    return out


def row(shot_paths, out, w=2400, h=1350, screen_w=None, gap_factor=1.30, labels=None):
    bg = canvas(w, h)
    n = len(shot_paths)
    screen_w = screen_w or int(w * 0.155 * (3 / max(3, n)))
    phones = [frame_phone(Image.open(p), screen_w) for p in shot_paths]
    step = phones[0].width * gap_factor
    total = step * (n - 1)
    for i, ph in enumerate(phones):
        cx = w / 2 - total / 2 + i * step
        place(bg, ph, cx, h * 0.5)
    bg.save(out, quality=94)
    return out
