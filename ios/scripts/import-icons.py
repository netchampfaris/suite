"""Copy the web app's duotone icons into the iOS asset catalog.

Area icons come from each app's `AreaIcon.vue`, file icons from Drive's
`file-icons/` folder. Both follow the duotone frame's rules (see
`frontend/src/platform/duotone-icon`). This script bakes the tones in as
opacities and saves each icon as a template image, so SwiftUI tints it the
way CSS's currentColor does. Run it from `ios/` after the web icons change:

    python3 scripts/import-icons.py
"""

import json
import re
from pathlib import Path

FRONTEND = Path(__file__).resolve().parents[2] / "frontend/src"
CATALOG = Path(__file__).resolve().parents[1] / "Suite/Assets.xcassets/Icons"

AREAS = {
    "home": "composition/home",
    "drive": "apps/drive",
    "mail": "apps/mail",
    "calendar": "apps/calendar",
    "meet": "apps/meet",
}
FILE_ICONS = FRONTEND / "apps/drive/files/internal/file-icons"
FRAME = (
    '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
    'stroke="#000" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">{}</svg>'
)
# The duotone frame's tones, from DuotoneIcon.vue.
TONES = {
    'data-tone="tint"': 'fill="#000" fill-opacity="0.1"',
    'data-tone="accent"': 'fill="#000" fill-opacity="0.5" stroke="none"',
}


def area_svg(folder: str) -> str:
    vue = (FRONTEND / folder / "AreaIcon.vue").read_text()
    body = re.search(r"<DuotoneIcon>(.*?)</DuotoneIcon>", vue, re.S).group(1)
    for tone, attributes in TONES.items():
        body = body.replace(tone, attributes)
    return FRAME.format(" ".join(body.split()))


def file_svg(path: Path) -> str:
    # CoreSVG needs a size and a concrete colour; the template image ignores the colour.
    svg = path.read_text().replace("currentColor", "#000")
    return svg.replace("<svg ", '<svg width="24" height="24" ', 1)


def save(name: str, svg: str) -> None:
    folder = CATALOG / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{name}.svg").write_text(svg + "\n")
    contents = {
        "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
    }
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main() -> None:
    CATALOG.mkdir(parents=True, exist_ok=True)
    (CATALOG / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    for area, folder in AREAS.items():
        save(f"area-{area}", area_svg(folder))
    for path in sorted(FILE_ICONS.glob("*.svg")):
        save(f"file-{path.stem}", file_svg(path))
    print(f"Wrote {len(AREAS)} area icons and {len(list(FILE_ICONS.glob('*.svg')))} file icons to {CATALOG}")


if __name__ == "__main__":
    main()
