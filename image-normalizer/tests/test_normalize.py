import io

import pytest
from PIL import Image, ImageDraw


def encode(image, fmt, **kwargs):
    out = io.BytesIO()
    image.save(out, fmt, **kwargs)
    return out.getvalue()


def decode(jpeg):
    return Image.open(io.BytesIO(jpeg))


def exif(orientation):
    data = Image.Exif()
    data[0x0112] = orientation
    return data.tobytes()


def test_16bit_gray_keeps_brightness(handler):
    image = Image.new("I;16", (800, 600))
    image.putdata([x * 65535 // 799 for _ in range(600) for x in range(800)])

    jpeg, width, height = handler.normalize(encode(image, "PNG"), 1, 1)

    result = decode(jpeg).convert("L")
    assert (width, height) == (800, 600)
    assert result.getpixel((0, 300)) <= 3
    assert abs(result.getpixel((400, 300)) - 128) <= 3
    assert result.getpixel((799, 300)) >= 252


@pytest.mark.parametrize("size, expected", [
    ((4096, 1025), (2048, 513)),
    ((4096, 1027), (2048, 514)),
    ((1025, 4096), (513, 2048)),
])
def test_long_edge_rounds_half_up_like_app(handler, size, expected):
    _, width, height = handler.normalize(encode(Image.new("RGB", size, (90, 120, 150)), "JPEG"), 1, 1)

    assert (width, height) == expected


def test_orientation_is_applied_before_min_size(handler):
    source = encode(Image.new("RGB", (300, 150), (0, 0, 0)), "JPEG", exif=exif(6))

    with pytest.raises(handler.InvalidImage, match="dimensions"):
        handler.normalize(source, 200, 200)
    assert handler.normalize(source, 100, 200)[1:] == (150, 300)


def test_transparent_png_is_composited_on_white(handler):
    image = Image.new("RGBA", (400, 300), (0, 0, 0, 0))
    ImageDraw.Draw(image).rectangle([0, 0, 199, 299], fill=(255, 0, 0, 255))

    jpeg, _, _ = handler.normalize(encode(image, "PNG"), 1, 1)

    result = decode(jpeg).convert("RGB")
    assert all(abs(a - b) <= 4 for a, b in zip(result.getpixel((100, 150)), (255, 0, 0)))
    assert all(c >= 251 for c in result.getpixel((300, 150)))


@pytest.mark.parametrize("fmt, reason", [("GIF", "format"), ("WEBP", "format")])
def test_other_formats_are_rejected(handler, fmt, reason):
    with pytest.raises(handler.InvalidImage, match=reason):
        handler.normalize(encode(Image.new("RGB", (400, 300)), fmt), 1, 1)


def test_truncated_jpeg_is_rejected(handler):
    data = encode(Image.effect_noise((900, 700), 64).convert("RGB"), "JPEG")

    with pytest.raises(handler.InvalidImage, match="decode"):
        handler.normalize(data[: len(data) // 2], 1, 1)
