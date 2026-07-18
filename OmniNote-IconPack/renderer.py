"""OmniNote icon renderer — procedural, sharp at any size."""
from PIL import Image, ImageDraw, ImageFilter

AMBER = (223, 165, 80, 255)       # #DFA550
DARK  = (21, 23, 28, 255)          # #15171C
TRANSPARENT = (0, 0, 0, 0)

# Proportions (fraction of the amber-field side length)
CORNER_RATIO   = 0.2237   # iOS squircle-ish
O_WIDTH_RATIO  = 0.44     # outer diameter (horizontal)
O_HEIGHT_RATIO = 0.48     # outer diameter (vertical) — slight elongation
O_STROKE_RATIO = 0.125    # stroke thickness

# --- SSAA for crisp edges at small sizes ---
SSAA = 4  # supersample factor

def _draw_o(canvas: Image.Image, cx: float, cy: float, field_side: float, color=DARK):
    """Draw the O letter on canvas at logical center (cx, cy), sized to field_side."""
    w = field_side * O_WIDTH_RATIO
    h = field_side * O_HEIGHT_RATIO
    stroke = field_side * O_STROKE_RATIO

    outer_l = cx - w/2
    outer_t = cy - h/2
    outer_r = cx + w/2
    outer_b = cy + h/2

    inner_l = outer_l + stroke
    inner_t = outer_t + stroke
    inner_r = outer_r - stroke
    inner_b = outer_b - stroke

    # Draw as filled outer ellipse minus inner ellipse (via mask)
    mask = Image.new("L", canvas.size, 0)
    md = ImageDraw.Draw(mask)
    md.ellipse([outer_l, outer_t, outer_r, outer_b], fill=255)
    md.ellipse([inner_l, inner_t, inner_r, inner_b], fill=0)

    fill = Image.new("RGBA", canvas.size, color)
    canvas.paste(fill, (0, 0), mask)


def render_icon(size: int, *, rounded: bool = True, padding: float = 0.0,
                bg_color=AMBER, letter_color=DARK, transparent_bg: bool = False,
                letter: bool = True, corner_ratio: float = CORNER_RATIO) -> Image.Image:
    """Render the OmniNote icon.

    size:            output pixel size (square).
    rounded:         if True, amber field has rounded corners; if False, fills whole canvas.
    padding:         fraction of canvas to leave as transparent border around the amber field.
    transparent_bg:  if True, background outside the amber field is transparent.
    letter:          whether to draw the O.
    """
    S = size * SSAA
    pad_px = int(S * padding)
    field_side = S - 2 * pad_px

    if transparent_bg:
        canvas = Image.new("RGBA", (S, S), TRANSPARENT)
    else:
        # Solid amber as backdrop when no rounding is requested and no padding
        canvas = Image.new("RGBA", (S, S), TRANSPARENT)

    # Amber field
    field_bbox = [pad_px, pad_px, pad_px + field_side, pad_px + field_side]
    d = ImageDraw.Draw(canvas)
    if rounded:
        radius = int(field_side * corner_ratio)
        d.rounded_rectangle(field_bbox, radius=radius, fill=bg_color)
    else:
        d.rectangle(field_bbox, fill=bg_color)

    # O letter
    if letter:
        cx = pad_px + field_side / 2
        cy = pad_px + field_side / 2
        _draw_o(canvas, cx, cy, field_side, color=letter_color)

    # Downsample with Lanczos for crisp anti-aliased edges
    return canvas.resize((size, size), Image.LANCZOS)


def render_o_only(size: int, safe_zone: float = 0.66) -> Image.Image:
    """Just the O on transparent background, sized for Android adaptive icon foreground.
    Android adaptive icons need the meaningful content inside a centered circle of
    diameter 66dp within the 108dp canvas — i.e. safe_zone=0.66.
    """
    S = size * SSAA
    canvas = Image.new("RGBA", (S, S), TRANSPARENT)
    # For adaptive icon foreground, we want the O sized proportional to the safe zone,
    # not the full canvas. Simulate a "field_side" equal to the safe zone.
    field_side = S * safe_zone
    _draw_o(canvas, S/2, S/2, field_side, color=DARK)
    return canvas.resize((size, size), Image.LANCZOS)


def render_solid_bg(size: int, color=AMBER) -> Image.Image:
    """Flat amber square for adaptive icon background."""
    return Image.new("RGBA", (size, size), color)


def render_circular(size: int) -> Image.Image:
    """Circular icon (for Android round launcher)."""
    S = size * SSAA
    canvas = Image.new("RGBA", (S, S), TRANSPARENT)
    d = ImageDraw.Draw(canvas)
    d.ellipse([0, 0, S, S], fill=AMBER)
    _draw_o(canvas, S/2, S/2, S, color=DARK)
    return canvas.resize((size, size), Image.LANCZOS)


def render_maskable(size: int) -> Image.Image:
    """PWA maskable icon: content within the inner 80% safe zone, amber fills the whole square."""
    S = size * SSAA
    canvas = Image.new("RGBA", (S, S), AMBER)
    # Draw O sized for 80% safe zone
    _draw_o(canvas, S/2, S/2, S * 0.80, color=DARK)
    return canvas.resize((size, size), Image.LANCZOS)


def render_splash(width: int, height: int, bg=(21, 23, 28, 255),
                  icon_fraction: float = 0.22, show_wordmark: bool = True) -> Image.Image:
    """Splash screen: dark background with centered rounded icon and optional wordmark."""
    img = Image.new("RGBA", (width, height), bg)
    icon_side = int(min(width, height) * icon_fraction)
    icon = render_icon(icon_side, rounded=True)
    ix = (width - icon_side) // 2
    iy = (height - icon_side) // 2 - int(min(width, height) * 0.03)
    img.paste(icon, (ix, iy), icon)

    if show_wordmark:
        # Wordmark: "OmniNote" in a bold sans, placed below the icon
        from PIL import ImageFont
        try:
            font_size = max(14, int(icon_side * 0.20))
            font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", font_size)
        except Exception:
            font = ImageFont.load_default()
        d = ImageDraw.Draw(img)
        text = "OmniNote"
        # measure
        bbox = d.textbbox((0, 0), text, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        tx = (width - tw) // 2
        ty = iy + icon_side + int(min(width, height) * 0.03)
        d.text((tx, ty), text, font=font, fill=(240, 240, 240, 255))
    return img
