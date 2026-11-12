"""Regression tests for independent, directly addressed legal pages."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "check_pages", Path(__file__).with_name("check_pages.py")
)
assert SPEC is not None and SPEC.loader is not None
check_pages = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check_pages)


class LegalPageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.docs = Path(self.temp.name) / "docs"
        self.write("contact/index.html", "<h1>Contact</h1>")
        self.write("one/index.html", '<a href="../contact/">Contact</a>')

    def write(self, relative: str, text: str) -> Path:
        path = self.docs / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            '<meta name="robots" content="noindex, nofollow">\n' + text,
            encoding="utf-8",
        )
        return path

    def errors(self) -> list[str]:
        return check_pages.validate_pages(self.docs)[1]

    def test_independent_pages_need_no_index(self) -> None:
        self.assertEqual((2, []), check_pages.validate_pages(self.docs))

    def test_index_is_forbidden_even_without_links(self) -> None:
        self.write("index.html", "<h1>Applications</h1>")
        self.assertTrue(any("index is not allowed" in e for e in self.errors()))

    def test_empty_docs_reports_missing_contact(self) -> None:
        self.assertEqual(
            (0, ["Missing required page: docs/contact/index.html"]),
            check_pages.validate_pages(self.docs / "missing"),
        )

    def test_missing_contact_and_broken_link_are_reported(self) -> None:
        (self.docs / "contact/index.html").unlink()
        self.assertEqual(2, len(self.errors()))
        self.assertTrue(any("Broken internal link" in e for e in self.errors()))

    def test_cross_policy_links_are_rejected_in_all_url_forms(self) -> None:
        self.write("two/index.html", "<h1>Two</h1>")
        for href in (
            "../two/",
            "../two/index.html#storage",
            "../%74wo/",
            "/Applications-legal/two/",
            "https://nioctren.github.io/Applications-legal/two/",
            "//nioctren.github.io/Applications-legal/two/",
        ):
            with self.subTest(href=href):
                self.write("one/index.html", f'<a href="{href}">Two</a>')
                self.assertTrue(any("Navigation to another policy" in e for e in self.errors()))

    def test_contact_cannot_list_policies_or_link_back_to_root(self) -> None:
        for href in (
            "../one/", "../", "/Applications-legal",
            "https://nioctren.github.io/Applications-legal",
        ):
            with self.subTest(href=href):
                self.write("contact/index.html", f'<a href="{href}">Back</a>')
                self.assertTrue(any("Navigation to another policy" in e for e in self.errors()))

    def test_local_anchors_contact_and_external_links_are_allowed(self) -> None:
        for href in (
            "#storage",
            "index.html#storage",
            "?lang=en",
            "../contact/",
            "https://nioctren.github.io/Applications-legal/contact/",
            "/Applications-legal/contact/",
            "https://example.org/privacy",
            "https://github.com/Nioctren/Applications-legal/issues/new",
            "mailto:privacy@example.org",
            "/outside-this-site/",
            "https://nioctren.github.io/other-site/",
        ):
            with self.subTest(href=href):
                self.write("one/index.html", f'<a href="{href}">Link</a>')
                self.assertEqual([], self.errors())

    def test_missing_same_policy_target_is_reported(self) -> None:
        self.write("one/index.html", '<a href="missing.html">Missing</a>')
        self.assertEqual(1, len(self.errors()))
        self.assertIn("Broken internal link", self.errors()[0])

    def test_path_outside_docs_is_rejected(self) -> None:
        self.write("one/index.html", '<a href="../../private.html">Outside</a>')
        self.assertTrue(any("outside legal pages" in e for e in self.errors()))

    def test_all_template_token_formats_are_rejected(self) -> None:
        for token in (
            "Template App",
            "YYYY-MM-DD",
            "FOUNDATION_DISPLAY_NAME_TOKEN",
            "FOUNDATION_DATE_TOKEN",
            "foundation_date_token",
            "Update this section if the application behavior changes.",
            "Document every sensitive Android permission introduced.",
        ):
            with self.subTest(token=token):
                self.write("one/index.html", f"<h1>{token}</h1>")
                self.assertTrue(any("Unresolved template token" in e for e in self.errors()))

    def test_missing_or_incomplete_robots_directives_are_rejected(self) -> None:
        for content in ("", '<meta name="robots" content="noindex">'):
            with self.subTest(content=content):
                (self.docs / "one/index.html").write_text(content, encoding="utf-8")
                self.assertTrue(any("Missing robots" in e for e in self.errors()))

    def test_main_surfaces_errors(self) -> None:
        with patch.object(check_pages, "validate_pages", return_value=(0, ["failure"])):
            with self.assertRaisesRegex(SystemExit, "failure"):
                check_pages.main()

    def test_main_prints_verified_count(self) -> None:
        with patch.object(check_pages, "validate_pages", return_value=(2, [])):
            with patch("builtins.print") as output:
                check_pages.main()
        output.assert_called_once_with("Validated 2 independent legal HTML pages.")

    def test_repository_has_all_nine_application_policies(self) -> None:
        expected = {
            "modly-space", "jurney", "kloo", "madeleine", "nomi",
            "pollup", "vago", "matinale", "echo", "contact",
        }
        actual = {
            page.parent.name for page in check_pages.DOCS.glob("*/index.html")
        }
        self.assertEqual(expected, actual)
        self.assertEqual((11, []), check_pages.validate_pages())

    def test_pollup_deletion_page_has_private_request_and_retention_details(self) -> None:
        page = check_pages.DOCS / "pollup/delete-account/index.html"
        text = page.read_text(encoding="utf-8")
        for phrase in (
            'lang="fr"', 'lang="en"', "mailto:nioctren@gmail.com",
            "Settings → Delete my account", "without reinstalling",
            "additional verification", "Other members retain",
            "90 days", "backup retention", "public GitHub issues",
        ):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, text)
        parser = check_pages.PageParser()
        parser.feed(text)
        self.assertIn("../", parser.links)
        self.assertFalse(any("github.com" in link for link in parser.links))

    def test_pollup_policy_describes_connected_app_and_links_deletion(self) -> None:
        page = check_pages.DOCS / "pollup/index.html"
        text = page.read_text(encoding="utf-8").lower()
        for phrase in (
            "last updated: 2026-11-12", "google sign-in", "supabase", "https",
            "reports are not anonymous", "90 days", "daily automatic maintenance",
            "wrapped", "backup retention", "mailto:nioctren@gmail.com",
            'href="delete-account/"', "other members retain",
            "testflight", "apple sign-in is not enabled",
            "7, 30 or 90 days", "180 days", "social graph",
        ):
            with self.subTest(phrase=phrase):
                self.assertIn(phrase, text)
        for obsolete in (
            "the application does not collect personal data",
            "it has no account, no sign-in and no backend",
            "the application does not transmit user data to external servers",
        ):
            self.assertNotIn(obsolete, text)

    def test_pollup_retention_matches_deployed_backend(self) -> None:
        policy = (check_pages.DOCS / "pollup/index.html").read_text(encoding="utf-8")
        deletion = (check_pages.DOCS / "pollup/delete-account/index.html").read_text(encoding="utf-8")
        for text in (policy, deletion):
            for phrase in ("03:00 UTC", "12 months", "90 days", "30 days after closure",
                           "ownership verification", "failed runs", "backup retention"):
                with self.subTest(page=text[:40], phrase=phrase):
                    self.assertIn(phrase, text)
            for obsolete in ("manual administrator purge", "manually purged",
                             "purge manuelle", "No automatic purge is configured",
                             "ballots and awards persist until group deletion"):
                self.assertNotIn(obsolete, text)
        for phrase in ("03:15 UTC", "seven days", "palette color",
                       "No group-photo upload", 'lang="fr"'):
            self.assertIn(phrase, policy)
        for phrase in ("12 mois", "90 jours", "30 jours après clôture", "délais légaux"):
            self.assertIn(phrase, deletion)

    def test_updated_policies_cover_current_privacy_surfaces(self) -> None:
        required = {
            "modly-space": ("camera", "notifications", "clipboard", "backup"),
            "jurney": ("post_notifications", "receive_boot_completed", "json", "clipboard", "lock screen"),
            "vago": ("sqlite", "file picker", "original", "external", "backup"),
            "matinale": ("geographic coordinates", "ip address", "interface language", "backup"),
            "echo": ("offline voices", "foreground_service_media_playback", "simulated location", "origin", "backup"),
        }
        for slug, phrases in required.items():
            with self.subTest(slug=slug):
                text = (check_pages.DOCS / slug / "index.html").read_text(encoding="utf-8").lower()
                self.assertIn("last updated: 2026-11-08", text)
                for phrase in phrases:
                    self.assertIn(phrase, text)


if __name__ == "__main__":
    unittest.main()
