# NoneSilva.github.io

Source of <https://NoneSilva.github.io/>, built by GitHub Pages with Jekyll.

## Public contributions

The home page (`index.html`) is the searchable public contributions of the
account, as GitHub records them: static HTML, the styles and data in
`contributions/`.

`contributions/structure.css` holds geometry, typography and layout;
`contributions/skin.css` holds only colours, read from the stylesheets GitHub
serves for its light and dark themes.

## GitHub Developer Program

The generator is the integration registered for the account in the
[GitHub Developer Program](https://docs.github.com/en/get-started/exploring-integrations/github-developer-program).

## Updating the public contributions data

To update it, run:

```sh
escript tools/catalog.escript
git commit -am "Update public contributions data"
git push
```

Requirements: OTP 27 or later (`json` module) and `gh` logged in as the
account.

## Data

- Listed: issues, pull requests, reviews, security advisories crediting the
  account (from the advisories of every repository it contributed to), the
  latest commit per repository (shown in "All"), and commits aggregated per
  repository per month (shown in "Commits"). Public repositories only.
- Counted but never listed: private repositories (`meta.restricted`).
- Not collected: discussions; advisories in repositories with no other
  contribution from the account.

## Share or Copy button

The Share or Copy button asks the browser whether it has the system's share sheet. That's `navigator.share`, from the Web Share API.

- **Phones, and computers on Windows, macOS or ChromeOS:** it does. The button shows as **Share** and opens the system's own share sheet.
- **Ubuntu and other Linux, and Firefox on desktop:** it doesn't, because the browser doesn't turn that feature on there. The button becomes **Copy**, copies the link and confirms with a green message.

The link carries the search, tab and dates in the address, so whoever opens it sees the same filtered list. And the Open Graph meta tags make LinkedIn and WhatsApp show the card with the icon and title.

## Installing the site

The site can be installed as an app: it has a web app manifest and home screen icons. The page has no install button; the browser offers it.

- **Chrome and Edge, on Android and on computers:** the browser menu offers to install it. Chrome on Android may also suggest it after a short visit.
- **iPhone:** in Safari, the share button, then Add to Home Screen.

Once installed, it opens full screen, without the address bar.

## Copyright

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
