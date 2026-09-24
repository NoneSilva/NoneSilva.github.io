# NoneSilva.github.io

Source of <https://NoneSilva.github.io/>, built by GitHub Pages with Jekyll.

1. [Public contributions](#1-public-contributions)
2. [Installing the site as a PWA](#2-installing-the-site-as-a-pwa)
3. [Accessibility](#3-accessibility)
4. [Share or Copy button](#4-share-or-copy-button)
5. [How updates reach visitors](#5-how-updates-reach-visitors)
6. [Data coverage](#6-data-coverage)
7. [Data refresh](#7-data-refresh)
8. [GitHub Developer Program](#8-github-developer-program)
9. [Copyright](#9-copyright)

## 1. Public contributions

The home page (`index.html`) is the searchable public contributions of the
account, as GitHub records them: static HTML, the styles and data in
`contributions/`.

`contributions/structure.css` holds geometry, typography and layout;
`contributions/skin.css` holds only colours, read from the stylesheets GitHub
serves for its light and dark themes.

## 2. Installing the site as a PWA

It has a web app manifest and home screen icons, but no service worker, so it needs a connection to load. The page has no install button; the browser offers it.

- **Chrome and Edge on computers:** an install icon in the address bar, or the browser menu.
- **Chrome and Samsung Internet on Android:** the browser menu. Chrome may also suggest it after a short visit.
- **iPhone:** the browser's share menu, then Add to Home Screen.

Once installed, it opens in its own window, without the address bar.

## 3. Accessibility

The page is tested against published standards, at every width from 320 to 1400px:

- **WCAG 2.2** ([2.5.8 Target Size](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html), [1.4.10 Reflow](https://www.w3.org/WAI/WCAG22/Understanding/reflow.html)) and the full WCAG 2.2 AA rule set through [axe-core](https://github.com/dequelabs/axe-core).
- **Material Design 3**: [48dp touch targets](https://m3.material.io/foundations/layout/understanding-layout/density) and [16dp margins in compact layouts](https://m3.material.io/foundations/layout/applying-layout/compact).
- **Android**: [8dp between touch targets](https://support.google.com/accessibility/android/answer/7101858).
- **Apple Human Interface Guidelines**: [44pt hit regions](https://developer.apple.com/design/human-interface-guidelines/buttons) and [consistent spacing](https://developer.apple.com/design/human-interface-guidelines/layout).

The standards, each with its source, are in `tools/a11y/standards.json`; the tests run on Playwright:

```sh
npm install
npx playwright test
```

They read the site as GitHub Pages builds it, in `_site`.

## 4. Share or Copy button

The Share or Copy button asks the browser whether it has the system's share sheet. That's `navigator.share`, from the Web Share API.

- **Phones, and computers on Windows, macOS or ChromeOS:** it does. The button shows as **Share** and opens the system's own share sheet.
- **Ubuntu and other Linux, and Firefox on desktop:** it doesn't, because the browser doesn't turn that feature on there. The button becomes **Copy**, copies the link and confirms with a green message.

The link carries the search, tab and dates in the address, so whoever opens it sees the same filtered list. And the Open Graph meta tags make LinkedIn and WhatsApp show the card with the icon and title.

## 5. How updates reach visitors

GitHub Pages renders `index.html` and `404.html` with Jekyll, and both carry the published commit (`site.github.build_revision`):

- The stylesheets are linked with the commit in their address, so every publication, data or layout, loads fresh styles, and a new page never meets old ones.
- When the page comes back on screen, it asks for the published page and reloads if the commit changed, so an installed copy updates without being closed.

Because Jekyll renders these pages, they must not contain `{{` or `{%` other than the build revision; the page test checks it.

## 6. Data coverage

- Listed: issues, pull requests, reviews, security advisories crediting the
  account (from the advisories of every repository it contributed to), the
  latest commit per repository (shown in "All"), and commits aggregated per
  repository per month (shown in "Commits"). Public repositories only.
- Counted but never listed: private repositories (`meta.restricted`).
- Not collected: discussions; advisories in repositories with no other
  contribution from the account.

## 7. Data refresh

To refresh the data:

```sh
escript tools/catalog.escript
git commit -am "Refresh the public contributions data"
git push
```

Requirements: OTP 27 or later (`json` module) and `gh` logged in as the
account.

## 8. GitHub Developer Program

The generator is the integration registered for the account in the
[GitHub Developer Program](https://docs.github.com/en/get-started/exploring-integrations/github-developer-program).

## 9. Copyright

Copyright (c) 2026 Guilherme Silva. All rights reserved.

This repository is public so that the site can be served, but no license is
granted: the code, styles and text may not be copied, modified or
redistributed without written permission.

What is claimed is the implementation: the generator, the page and the two
stylesheets. The visual conventions the page follows (GitHub's tab bar, list
rows, state icons and colours) are layout, free to follow and not claimed
here. In the words of the U.S. Copyright Office,
[Circular 33, Works Not Protected by Copyright](https://www.copyright.gov/circs/circ33.pdf),
section "Layout and Design":

> As a general rule, the Office will not accept a claim to copyright in
> "format" or "layout." The general layout or format of a book, page, book
> cover, slide presentation, web page, poster, or form is uncopyrightable
> because it is a template for expression.

The icon paths are [Octicons](https://github.com/primer/octicons), copyright
GitHub Inc., under their own MIT license; the LinkedIn mark is LinkedIn's,
used as a link to the account's profile; the typeface is Mona Sans,
copyright GitHub Inc., under the SIL Open Font License
(`contributions/fonts/OFL.txt`). The GitHub mark in the
header is a registered trademark of GitHub Inc., which no license here
covers; it appears only as a link to the account's profile, as GitHub's
[logo guidelines](https://brand.github.com/foundations/logo) permit.
