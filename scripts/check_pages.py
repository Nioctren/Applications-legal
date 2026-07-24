"""Validate public legal HTML pages with Python's standard library."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "a":
            return
        href = dict(attrs).get("href")
        if href:
            self.links.append(href)


def resolve_link(page: Path, href: str) -> Path | None:
    parsed = urlparse(href)
    if parsed.scheme or href.startswith("#") or href.startswith("mailto:"):
        return None
    candidate = (page.parent / parsed.path).resolve()
    if candidate.is_dir():
        candidate /= "index.html"
    return candidate


def main() -> None:
    required = [DOCS / "index.html", DOCS / "contact" / "index.html"]
    missing = [str(path.relative_to(ROOT)) for path in required if not path.is_file()]
    if missing:
        raise SystemExit(f"Missing required pages: {', '.join(missing)}")

    errors: list[str] = []
    pages = sorted(DOCS.rglob("*.html"))
    for page in pages:
        text = page.read_text(encoding="utf-8")
        parser = PageParser()
        parser.feed(text)
        parser.close()

        if "_templates" not in page.parts and ("Template App" in text or "YYYY-MM-DD" in text):
            errors.append(f"Unresolved template token in {page.relative_to(ROOT)}")

        for href in parser.links:
            target = resolve_link(page, href)
            if target is not None and not target.is_file():
                errors.append(
                    f"Broken internal link in {page.relative_to(ROOT)}: {href}"
                )

    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Validated {len(pages)} legal HTML pages.")


if __name__ == "__main__":
    main()