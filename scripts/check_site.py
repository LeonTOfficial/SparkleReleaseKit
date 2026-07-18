#!/usr/bin/env python3
"""Validate the static documentation website using only Python's standard library."""

from __future__ import annotations

import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "website"
PLACEHOLDER = re.compile(r"\{\{[A-Z0-9_]+\}\}")


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.targets: list[tuple[str, str]] = []
        self.ids: list[str] = []
        self.has_main = False
        self.has_title = False
        self.has_viewport = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "main":
            self.has_main = True
        if tag == "meta" and attributes.get("name") == "viewport":
            self.has_viewport = True
        if tag == "title":
            self.has_title = True
        if identifier := attributes.get("id"):
            self.ids.append(identifier)
        for name in ("href", "src"):
            if target := attributes.get(name):
                self.targets.append((name, target))


def local_target(page: Path, raw_target: str) -> Path | None:
    split = urlsplit(raw_target)
    if split.scheme or split.netloc or raw_target.startswith("mailto:"):
        return None
    decoded = unquote(split.path)
    if not decoded:
        return None
    candidate = SITE / decoded.lstrip("/") if decoded.startswith("/") else page.parent / decoded
    candidate = candidate.resolve(strict=False)
    try:
        candidate.relative_to(SITE.resolve())
    except ValueError:
        raise ValueError(f"Local target escapes website root: {raw_target}") from None
    if candidate.is_dir():
        candidate /= "index.html"
    return candidate


def main() -> int:
    errors: list[str] = []
    pages = sorted(SITE.rglob("*.html"))
    parsed_pages: dict[Path, PageParser] = {}
    if not pages:
        errors.append("No HTML pages found.")

    for page in pages:
        relative = page.relative_to(ROOT)
        source = page.read_text(encoding="utf-8")
        if PLACEHOLDER.search(source):
            errors.append(f"{relative}: unrendered template placeholder")

        parser = PageParser()
        try:
            parser.feed(source)
            parser.close()
        except Exception as error:  # HTMLParser reports malformed parser state here.
            errors.append(f"{relative}: HTML parsing failed: {error}")
            continue
        parsed_pages[page.resolve()] = parser

        if not parser.has_title:
            errors.append(f"{relative}: missing title")
        if not parser.has_viewport:
            errors.append(f"{relative}: missing viewport metadata")
        if not parser.has_main:
            errors.append(f"{relative}: missing main landmark")

        duplicates = sorted({value for value in parser.ids if parser.ids.count(value) > 1})
        for duplicate in duplicates:
            errors.append(f"{relative}: duplicate id '{duplicate}'")

        for _, target in parser.targets:
            try:
                resolved = local_target(page, target)
            except ValueError as error:
                errors.append(f"{relative}: {error}")
                continue
            if resolved is not None and not resolved.exists():
                errors.append(f"{relative}: broken local target '{target}'")

    for page, parser in parsed_pages.items():
        relative = page.relative_to(ROOT)
        for name, target in parser.targets:
            if name != "href":
                continue
            split = urlsplit(target)
            if split.scheme or split.netloc or not split.fragment:
                continue
            try:
                resolved = local_target(page, target) or page
            except ValueError:
                continue
            target_parser = parsed_pages.get(resolved.resolve())
            fragment = unquote(split.fragment)
            if target_parser is not None and fragment not in target_parser.ids:
                errors.append(f"{relative}: missing local fragment '#{fragment}' in '{target}'")

    if errors:
        print("Website validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"Website validation passed for {len(pages)} HTML pages.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
