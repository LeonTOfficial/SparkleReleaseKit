#!/usr/bin/env python3
"""Validate the static documentation website using only Python's standard library."""

from __future__ import annotations

import os
import re
import sys
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "website"
PLACEHOLDER = re.compile(r"\{\{[A-Z0-9_]+\}\}")
BIDI_CONTROLS = {
    *range(0x200B, 0x2010),
    *range(0x202A, 0x202F),
    *range(0x2066, 0x206A),
}


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


def terminal_text(value: str) -> str:
    result: list[str] = []
    for character in value:
        scalar = ord(character)
        if 0x20 <= scalar <= 0x7E or (
            scalar >= 0xA0 and scalar not in BIDI_CONTROLS
        ):
            result.append(character)
        else:
            result.append(f"\\u{{{scalar:X}}}")
    return "".join(result)


def checked_local_path(candidate: Path, site: Path) -> Path:
    site_lexical = site.absolute()
    lexical = Path(os.path.abspath(candidate))
    try:
        relative = lexical.relative_to(site_lexical)
    except ValueError:
        raise ValueError("Local target escapes website root") from None

    current = site_lexical
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise ValueError(
                f"Local target uses forbidden symbolic link: {current.name}"
            )

    resolved = lexical.resolve(strict=False)
    try:
        resolved.relative_to(site.resolve())
    except ValueError:
        raise ValueError("Local target resolves outside website root") from None
    return resolved


def local_target(page: Path, raw_target: str, site: Path = SITE) -> Path | None:
    split = urlsplit(raw_target)
    if split.scheme or split.netloc or raw_target.startswith("mailto:"):
        return None
    decoded = unquote(split.path)
    if not decoded:
        return None
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in decoded):
        raise ValueError("Local target contains a control character")
    candidate = site / decoded.lstrip("/") if decoded.startswith("/") else page.parent / decoded
    candidate = checked_local_path(candidate, site)
    if candidate.is_dir():
        candidate = checked_local_path(candidate / "index.html", site)
    return candidate


def main() -> int:
    errors: list[str] = []
    for candidate in sorted(SITE.rglob("*")):
        if candidate.is_symlink():
            errors.append(
                f"{candidate.relative_to(ROOT)}: symbolic links are not allowed in the website"
            )

    pages = sorted(SITE.rglob("*.html"))
    parsed_pages: dict[Path, PageParser] = {}
    if not pages:
        errors.append("No HTML pages found.")

    for page in pages:
        relative = page.relative_to(ROOT)
        try:
            checked_local_path(page, SITE)
        except ValueError as error:
            errors.append(f"{relative}: {error}")
            continue
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

        duplicates = sorted(
            value for value, count in Counter(parser.ids).items() if count > 1
        )
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
            print(f"- {terminal_text(error)}", file=sys.stderr)
        return 1

    print(f"Website validation passed for {len(pages)} HTML pages.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
