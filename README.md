# Applications Legal

Public legal pages for Nioctren applications, hosted with GitHub Pages.

## Public URL

- Contact: `https://nioctren.github.io/Applications-legal/contact/`
- Poll Up account deletion: `https://nioctren.github.io/Applications-legal/pollup/delete-account/`

Poll Up deletion requests use the private email channel on that page, not public
GitHub issues. The publisher must monitor the mailbox, verify account ownership
and complete the application's account-erasure process, including authentication
deletion and any pending retries. Publishing instructions does not automate
deletion or finalize provider log/backup retention.

Poll Up's 2026-11-10 policy describes deployed daily retention: closed Daily Vote
ballots erased after progression recording, collective results purged after
12 months and reports after 90 days, with pause/failure caveats. Its deletion
page carries the same rules in French and English. Support deadlines are manual
publisher targets, not automation. Provider log/backup durations remain unverified.

## Add an application

1. Copy `templates/privacy-policy.html` to `docs/<legal-slug>/index.html`.
2. Replace `FOUNDATION_DISPLAY_NAME_TOKEN` and `FOUNDATION_DATE_TOKEN`.
3. Review every statement against the application's real behavior.
4. Keep the page independent: no policy index and no links to other applications.
5. Run `python scripts/check_pages.py` and `python -m unittest discover -s scripts -p "test_*.py"`.
6. Review, commit, and push manually.

One application uses one lowercase kebab-case folder. Never publish secrets,
personal data, signing material, or private repository details in these pages.

There is deliberately no `docs/index.html`. Each application links directly to
its own policy URL. The shared contact page must not link to policies or an index.
This avoids navigation between applications, but is not access control: these
pages and this repository are public, so URLs can still be discovered or shared.
All HTML pages use `robots: noindex, nofollow` to discourage indexing and link
following by compliant search engines. This is advisory, not a guarantee of
secrecy; it does not hide files in the public repository.

Policy updates are manual, not automatic copies of application documentation.
Review storage, sharing, network requests, permissions and Android backup before
each release. A local edit is not published until committed, pushed and deployed
by GitHub Pages.