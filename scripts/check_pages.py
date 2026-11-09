"""Validate public legal HTML pages with Python's standard library."""
from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
PUBLIC_HOST = "nioctren.github.io"
PUBLIC_PREFIX = "/Applications-legal/"


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []
        self.robots: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "meta" and (attributes.get("name") or "").lower() == "robots":
            self.robots.update(
                value.strip().lower()
                for value in (attributes.get("content") or "").split(",")
            )
        if tag != "a":
            return
        href = attributes.get("href")
        if href:
            self.links.append(href)


def resolve_link(page: Path, href: str, docs: Path = DOCS) -> Path | None:
    parsed = urlparse(href)
    if href.startswith("#"):
        return None
    if parsed.netloc:
        if parsed.hostname != PUBLIC_HOST:
            return None
        path = unquote(parsed.path)
        if path == PUBLIC_PREFIX.rstrip("/"):
            path += "/"
        if not path.startswith(PUBLIC_PREFIX):
            return None
        candidate = (docs / path[len(PUBLIC_PREFIX):]).resolve()
    elif parsed.scheme:
        return None
    elif parsed.path.startswith("/"):
        path = unquote(parsed.path)
        if path == PUBLIC_PREFIX.rstrip("/"):
            path += "/"
        if not path.startswith(PUBLIC_PREFIX):
            return None
        candidate = (docs / path[len(PUBLIC_PREFIX):]).resolve()
    else:
        candidate = (page.parent / unquote(parsed.path)).resolve()
    if candidate.is_dir():
        candidate /= "index.html"
    return candidate


def validate_pages(docs: Path = DOCS) -> tuple[int, list[str]]:
    docs = docs.resolve()
    errors: list[str] = []
    if not (docs / "contact" / "index.html").is_file():
        errors.append("Missing required page: docs/contact/index.html")
    if (docs / "index.html").exists():
        errors.append("A policy index is not allowed: docs/index.html")

    pages = sorted(docs.rglob("*.html"))
    for page in pages:
        text = page.read_text(encoding="utf-8")
        label = f"docs/{page.relative_to(docs).as_posix()}"
        parser = PageParser()
        parser.feed(text)
        parser.close()
        if not {"noindex", "nofollow"}.issubset(parser.robots):
            errors.append(f"Missing robots noindex, nofollow directives in {label}")

        if (
            "Template App" in text
            or "YYYY-MM-DD" in text
            or re.search(r"FOUNDATION_[A-Z_]+_TOKEN", text, re.IGNORECASE)
            or "Update this section" in text
            or "Document every sensitive Android permission" in text
        ):
            errors.append(f"Unresolved template token in {label}")

        for href in parser.links:
            target = resolve_link(page, href, docs)
            if target is None:
                continue
            if not target.is_relative_to(docs):
                errors.append(f"Link outside legal pages in {label}: {href}")
                continue
            relative = target.relative_to(docs)
            source_slug = page.relative_to(docs).parts[0]
            target_slug = relative.parts[0] if relative.parts else ""
            if target_slug not in (source_slug, "contact"):
                errors.append(f"Navigation to another policy or index in {label}: {href}")
            if not target.is_file():
                errors.append(f"Broken internal link in {label}: {href}")

    return len(pages), errors


def main() -> None:
    count, errors = validate_pages()
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Validated {count} independent legal HTML pages.")


if __name__ == "__main__":
    main()