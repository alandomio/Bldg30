#!/usr/bin/env python3
"""Validate the bilingual catalog without third-party dependencies."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate translation key: {key}")
        result[key] = value
    return result

catalog = json.loads((root / "Sources/ModelDeckCore/Resources/English.json").read_text(), object_pairs_hook=unique)
for source, target in catalog.items():
    if not source or not isinstance(target, str) or not target:
        raise ValueError(f"Empty or invalid translation: {source}")
    if source.count("%@") != target.count("%@"):
        raise ValueError(f"Interpolation count changed: {source}")
print(f"Validated {len(catalog)} English translations and interpolation counts")
