"""v2 case-study imagery.

Lesson from auditing the hand-built pages: every media block there is
~1.7:1 and the SUBJECT FILLS IT. An upright phone never fills a landscape
frame, so there are only two honest options — crop into the UI until it
bleeds off all four edges, or line up enough devices to span the width.
Both are used here, alternating dark UI crops with light device rows so
the page stops being uniformly black.
"""
from PIL import Image, ImageDraw, ImageFilter
import math

RATIO = 1.7  # matches the template's media blocks


def rounded_mask(size, radius, ss=4):
    w, h = size
    m = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w * ss - 1, h * ss - 1],
                                        radius=radius * ss, fill=255)
    return m.resize(size, Image.LANCZOS)


def frame_phone(shot, screen_w, dark_device=True):
    ratio = shot.height / shot.width
    screen_h = int(round(screen_w * ratio))
    screen = shot.convert("RGB").resize((screen_w, screen_h), Image.LANCZOS)
    scr_r = int(screen_w * 0.095)
    bezel = max(3, int(screen_w * 0.022))
    rim = max(2, int(screen_w * 0.012))
    bw, bh = screen_w + 2 * (bezel + rim), screen_h + 2 * (bezel + rim)
    phone = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))

    rim_img = Image.new("RGB", (bw, bh))
    rd = ImageDraw.Draw(rim_img)
    for y in range(bh):
        t = y / max(1, bh - 1)
        shade = 0.5 + 0.5 * math.sin(math.pi * t)
        v = 120 + int(72 * shade)
        rd.line([(0, y), (bw, y)], fill=(v, v - 4, v - 9))
    phone.paste(rim_img, (0, 0), rounded_mask((bw, bh), scr_r + bezel + rim))
    phone.paste(Image.new("RGB", (screen_w + 2 * bezel, screen_h + 2 * bezel), (8, 8, 10)),
                (rim, rim), rounded_mask((screen_w + 2 * bezel, screen_h + 2 * bezel), scr_r + bezel))
    phone.paste(screen, (rim + bezel, rim + bezel), rounded_mask((screen_w, screen_h), scr_r))
    return phone


def light_canvas(w, h):
    """Soft neutral studio backdrop — the reference pages shoot on light walls."""
    bg = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(bg)
    top, bot = (243, 243, 245), (214, 216, 221)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).ellipse([w * 0.12, -h * 0.35, w * 0.88, h * 0.75], fill=90)
    bg.paste(Image.new("RGB", (w, h), (255, 255, 255)), (0, 0),
             glow.filter(ImageFilter.GaussianBlur(w // 7)))
    return bg


def shadow(phone, blur=40, dy=30, opacity=95):
    pad = blur * 3
    sh = Image.new("RGBA", (phone.width + pad * 2, phone.height + pad * 2), (0, 0, 0, 0))
    sh.paste(Image.new("RGBA", phone.size, (20, 22, 30, opacity)), (pad, pad + dy), phone.split()[3])
    return sh.filter(ImageFilter.GaussianBlur(blur)), pad


def device_row(paths, out, w=2400, fill=0.86, gap=1.13):
    """N phones spanning the frame on a light backdrop."""
    h = int(w / RATIO)
    bg = light_canvas(w, h)
    n = len(paths)
    phone_h = int(h * fill)
    screen_w = int(phone_h / 2.245)
    phones = [frame_phone(Image.open(p), screen_w) for p in paths]
    step = phones[0].width * gap
    total = step * (n - 1)
    for i, ph in enumerate(phones):
        cx = w / 2 - total / 2 + i * step
        sh, pad = shadow(ph)
        bg.paste(sh, (int(cx - ph.width / 2) - pad, int(h / 2 - ph.height / 2) - pad), sh)
        bg.paste(ph, (int(cx - ph.width / 2), int(h / 2 - ph.height / 2)), ph)
    bg.save(out, quality=93)
    return out


def ui_crop(path, out, box, w=2400):
    """Crop into the interface until it bleeds off every edge."""
    h = int(w / RATIO)
    im = Image.open(path).convert("RGB").crop(box)
    # cover-fit the crop into the frame
    s = max(w / im.width, h / im.height)
    im = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
    left = (im.width - w) // 2
    top = (im.height - h) // 2
    im.crop((left, top, left + w, top + h)).save(out, quality=93)
    return out
