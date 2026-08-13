#!/usr/bin/env python3
"""Flatten App Store screenshots to opaque RGB, refusing anything lossy.

App Store Connect rejects PNGs carrying an alpha channel. A simulator
capture always has one, and it is always fully opaque — so dropping it is a
channel removal, not a composite, and the pixels a reviewer sees are the
pixels the app drew.

That "always" is the part worth checking rather than trusting: if any pixel
were actually transparent, dropping alpha would silently composite it
against whatever RGB happened to sit underneath, and the frame shipped to
the store would differ from the frame the app rendered. So this refuses on
the first non-opaque pixel instead of producing a plausible-looking file.

Usage:  Tools/appstore_flatten.py <in.png> <out.png> [--expect WxH]

The one-off script that produced the first set of captures lived in a
session scratchpad and is gone (PR #95); this is that step, kept.
"""
import sys

from PIL import Image


def flatten(src: str, dst: str, expect: str | None) -> int:
    image = Image.open(src)

    if expect:
        want = tuple(int(n) for n in expect.lower().split("x"))
        if image.size != want:
            print(f"!!  {src} is {image.size[0]}x{image.size[1]}, expected "
                  f"{want[0]}x{want[1]} — wrong simulator, or a scaled capture.",
                  file=sys.stderr)
            return 1

    if image.mode in ("RGBA", "LA") or "transparency" in image.info:
        alpha = image.convert("RGBA").getchannel("A")
        low, high = alpha.getextrema()
        if low != 255:
            print(f"!!  {src} has a non-opaque pixel (min alpha {low}).",
                  file=sys.stderr)
            print("!!  Dropping alpha would composite it against an "
                  "arbitrary background, so the store frame would no longer "
                  "be what the app drew. Refusing.", file=sys.stderr)
            return 1

    # Every pixel is opaque, so this discards a constant channel and touches
    # no colour value. Saved without alpha; dimensions are untouched.
    image.convert("RGB").save(dst, format="PNG", optimize=True)

    check = Image.open(dst)
    if check.mode != "RGB" or check.size != image.size:
        print(f"!!  {dst} came back as {check.mode} {check.size} — "
              f"expected RGB {image.size}.", file=sys.stderr)
        return 1
    print(f"==> {dst}  {check.size[0]}x{check.size[1]}  RGB, no alpha")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    expect = None
    if "--expect" in argv:
        expect = argv[argv.index("--expect") + 1]
    return flatten(argv[1], argv[2], expect)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
