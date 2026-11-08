#!/usr/bin/env python3
"""Builds the app's String Catalog and its Swift accessors from the web repo's messages, the one source for every string.

    python3 scripts/sync-strings.py [path to the kosha web repo, default ../kosha-web]

Reads messages/<locale>/<area>.json (inlang message format) for the areas the app shows and writes
KoshaKit/Sources/Design/Resources/Localizable.xcstrings and KoshaKit/Sources/Design/Strings.swift.

Each message keeps the web's text, `{name}` variables and `{#tag}…{/tag}` markup; `L` fills the variables by name
and strips the markup (`Msg.segments` keeps it). A plural message is stored as one catalog entry per case,
`key|one`, `key|any`, or `key|one|any` for messages with two selectors, and `L` picks the case with the language's
CLDR plural rules through the `kosha.plural` entry. Add app-only strings to messages/<locale>/app.json (or
app-<feature>.json) in the web repo, in every locale, then run this again.
"""
import json
import keyword
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WEB = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT.parent / "kosha-web")
CATALOG = ROOT / "KoshaKit/Sources/Design/Resources/Localizable.xcstrings"
SWIFT = ROOT / "KoshaKit/Sources/Design/Strings.swift"
# The same areas as the Android app: landing, demos and legal are the web's marketing pages.
AREAS = ["common", "auth", "overview", "transactions", "add", "accounts", "reconcile", "import", "welcome",
         "settings", "settings-sections", "ai", "site", "server", "app"]
AREAS += sorted(p.stem for p in (WEB / "messages/en").glob("app-*.json"))
CATEGORIES = ["zero", "one", "two", "few", "many", "other"]
SWIFT_KEYWORDS = {"default", "in", "for", "if", "else", "switch", "case", "return", "var", "let", "func", "class",
                  "struct", "enum", "protocol", "extension", "import", "where", "while", "repeat", "is", "as", "self",
                  "Self", "true", "false", "nil", "try", "throw", "do", "catch", "break", "continue", "operator",
                  "internal", "private", "public", "static", "subscript", "init", "deinit", "inout", "Type", "Any"}


def load(locale: str) -> dict:
    out = {}
    for area in AREAS:
        out.update(json.loads((WEB / f"messages/{locale}/{area}.json").read_text()))
    out.pop("$schema", None)
    return out


def ident(name: str) -> str:
    return f"`{name}`" if name in SWIFT_KEYWORDS or keyword.iskeyword(name) else name


def plural_inputs(value) -> list[str]:
    """The input each selector counts, in selector order: "local countPlural = count: plural" gives count."""
    decl = {}
    for d in value[0]["declarations"]:
        m = re.match(r"local (\w+) = (\w+): plural", d)
        if m:
            decl[m.group(1)] = m.group(2)
    return [decl[s] for s in value[0]["selectors"]]


def cases(value) -> dict[str, str]:
    """`countPlural=one, accountsPlural=*` becomes `one|any`."""
    out = {}
    for match, text in value[0]["match"].items():
        out["|".join(part.split("=", 1)[1].strip().replace("*", "any") for part in match.split(","))] = text
    return out


def unit(text: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": text}}


def main():
    english = load("en")
    locales = sorted(p.name for p in (WEB / "messages").iterdir() if p.is_dir())
    per_locale = {loc: (english if loc == "en" else load(loc)) for loc in locales}
    strings: dict[str, dict] = {}

    def put(key: str, locale: str, text: str):
        strings.setdefault(key, {"extractionState": "manual", "localizations": {}})["localizations"][locale] = unit(text)

    # The plural probe: each language's CLDR rules pick the case name for a count.
    strings["kosha.plural"] = {
        "extractionState": "manual",
        "localizations": {
            loc: {"variations": {"plural": {c: unit(f"%lld|{c}") for c in CATEGORIES}}} for loc in locales
        },
    }
    funcs = []
    for key, value in english.items():
        if isinstance(value, str):
            names = list(dict.fromkeys(re.findall(r"\{(\w+)\}", value)))
            for loc in locales:
                text = per_locale[loc].get(key)
                if isinstance(text, str):
                    put(key, loc, text)
            params = ", ".join(f"{ident(n)}: String" for n in names)
            args = ", ".join(f'"{n}": {ident(n)}' for n in names)
            body = f'L.text("{key}", [{args or ":"}])'
            funcs.append(f"    public static func {key}({params}) -> String {{ {body} }}")
            continue
        inputs = plural_inputs(value)
        texts = list(cases(value).values())
        names = list(dict.fromkeys(n for t in texts for n in re.findall(r"\{(\w+)\}", t)))
        for loc in locales:
            v = per_locale[loc].get(key)
            if isinstance(v, list):
                for case, text in cases(v).items():
                    put(f"{key}|{case}", loc, text)
        params = [f"{ident(n)}: Int" for n in inputs] + [f"{ident(n)}: String" for n in names if n not in inputs]
        args = ", ".join([f'"{n}": String({ident(n)})' for n in inputs] + [f'"{n}": {ident(n)}' for n in names if n not in inputs])
        counts = ", ".join(ident(n) for n in inputs)
        funcs.append(f"    public static func {key}({', '.join(params)}) -> String {{ "
                     f'L.plural("{key}", [{counts}], [{args or ":"}]) }}')

    catalog = {"sourceLanguage": "en", "strings": dict(sorted(strings.items())), "version": "1.0"}
    CATALOG.parent.mkdir(parents=True, exist_ok=True)
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
    SWIFT.write_text(
        "// Generated by scripts/sync-strings.py from the web repo's messages. Don't edit.\n"
        "// swiftlint:disable all\n\n"
        "extension L {\n" + "\n".join(funcs) + "\n}\n"
    )
    print(f"{len(english)} messages, {len(locales)} locales, {len(strings)} catalog entries")


main()
