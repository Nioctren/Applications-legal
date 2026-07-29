# Applications Legal

Public legal pages for Nioctren applications, hosted with GitHub Pages.

## Public URLs

- Index: `https://nioctren.github.io/Applications-legal/`
- Contact: `https://nioctren.github.io/Applications-legal/contact/`

## Add an application

1. Copy `templates/privacy-policy.html` to `docs/<legal-slug>/index.html`.
2. Replace `Template App` and `YYYY-MM-DD`.
3. Review every statement against the application's real behavior.
4. Add the application to `docs/index.html`.
5. Run `python scripts/check_pages.py`.
6. Review, commit, and push manually.

One application uses one lowercase kebab-case folder. Never publish secrets,
personal data, signing material, or private repository details in these pages.