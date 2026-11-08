#!/usr/bin/env python3
"""Writes the Phosphor icon names and their code points, which the regular and fill fonts share.

    python3 scripts/phosphor-codes.py <unpacked @phosphor-icons/web package>/src/regular/style.css

Output: KoshaKit/Sources/Design/Resources/phosphor.txt, one "name hex" line per icon. Icons are drawn by name
(`PhIcon("shopping-cart")`), so a category's `ph:<name>` icon from the server works without a code change. The fonts
(phosphor.ttf, phosphor_fill.ttf) come from the same package and sit in Resources/Fonts.
"""
import re
import sys
from pathlib import Path

css = Path(sys.argv[1]).read_text()
pairs = re.findall(r'\.ph-([a-z0-9-]+):before\s*\{\s*content:\s*"\\([0-9a-f]+)"', css)
out = Path(__file__).resolve().parents[1] / "KoshaKit/Sources/Design/Resources/phosphor.txt"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("".join(f"{name} {code}\n" for name, code in pairs))
print(f"{len(pairs)} icons")
