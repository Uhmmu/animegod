#!/usr/bin/env python3
"""Lists String Catalog entries that are missing or stale per language.

    scripts/check-localizations.py            # summary, exit 1 if anything is missing
    scripts/check-localizations.py --list ja  # every untranslated key for one language

Entries marked "shouldTranslate": false (brand names, placeholders) are
skipped. Plural variations count as translated when every variant is.
"""
import json
import sys

CATALOGS = ["App/Localizable.xcstrings", "Sources/AnimeGodCore/Resources/Localizable.xcstrings"]
LANGUAGES = ["zh-Hans", "ja"]


def translated(unit):
    if "stringUnit" in unit:
        return unit["stringUnit"].get("state") == "translated"
    variations = unit.get("variations", {})
    for kind in variations.values():
        for variant in kind.values():
            if not translated(variant):
                return False
    return bool(variations)


def main():
    listing = sys.argv[2] if len(sys.argv) > 2 and sys.argv[1] == "--list" else None
    failed = False
    for path in CATALOGS:
        with open(path, encoding="utf-8") as handle:
            strings = json.load(handle)["strings"]
        active = {k: v for k, v in strings.items()
                  if v.get("shouldTranslate", True) and v.get("extractionState") != "stale" and k.strip()}
        stale = [k for k, v in strings.items() if v.get("extractionState") == "stale"]
        print(f"{path}: {len(active)} strings, {len(stale)} stale")
        for language in LANGUAGES:
            missing = [k for k, v in active.items() if not translated(v.get("localizations", {}).get(language, {}))]
            print(f"  {language}: {len(active) - len(missing)}/{len(active)} translated")
            if missing:
                failed = True
            if listing == language:
                for key in missing:
                    print(f"    {key!r}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
