# TrayNook landing page

A static Astro page with system fonts, a warm palette drawn from the canonical
icon, and real native images of TrayNook’s Settings → Layout and dropdown.
Astro is the only direct build dependency; the page uses plain browser JavaScript.
No analytics, external fonts, or backend.

## Preview and checks

Requires Node.js 22.23.4 or newer and npm 9.6.5 or newer. From the repository root:

```sh
npm --prefix website ci
npm --prefix website run dev
```

Open <http://localhost:4173>. Stop the development server with **Ctrl+C**.
If the port is occupied, use `npm --prefix website run dev -- --port 4180`.
Build the static output in `website/dist/` and check it:

```sh
npm --prefix website run build
npm --prefix website test
python3 website/check.py
```

Preview the build with `npm --prefix website run preview`. Astro's background
preview can be stopped from `website/` with
`ASTRO_TELEMETRY_DISABLED=1 npx astro preview stop`. The configured production URL
for GitHub Pages is <https://traynook.mahenzon.ru>. Deployment and DNS
setup are separate steps; the npm scripts disable Astro telemetry.

## Languages

- `/` serves English HTML, then selects the first supported browser language.
  Regional tags such as `ru-RU` and `en-GB` are supported; the fallback is English.
- `/en/` and `/ru/` always show their requested language without redirecting.
  The header's EN/RU links save an explicit choice in `traynook.language` in
  local storage. That choice takes priority when revisiting `/`.
- If storage is blocked, language links and browser detection still work. If
  JavaScript is disabled, `/` stays English and both language links still work.
- Copy lives in `src/i18n/en.json` and `src/i18n/ru.json`; the shared layout is
  `src/components/Landing.astro`. Metadata, image descriptions, accessibility labels,
  and social images are localized. The native app currently uses English, so
  its interface labels stay English in the native images and instructions.

The Russian draft received an editorial pass with the requested
[Humanizer RU skill](https://github.com/Vladimir-Human/humanizer-ru/blob/main/skills/humanizer-ru/SKILL.md).
Its fact-check helper reported no errors or review flags. The skill is an editing
guide, not a runtime dependency.

## Appearance

The header's appearance menu defaults to **Auto**, following the system theme,
including changes while the page is open. **Light** and **Dark** override the
system and save the choice in `traynook.theme` in local storage. Choosing Auto
removes that override. The choice is shared across both language pages.

The saved preference applies before the body paints. If storage is blocked,
manual switching still works for the current page. Without JavaScript, the menu
stays hidden and the page continues to follow the system through CSS. Dark rules
live in `src/styles/dark.css`; `src/scripts/theme.js` controls the stylesheet's
media condition and the browser's color scheme and theme-color hints.

## GitHub links and counts

The header links to the repository. Beneath the main CTA, Stars opens the
repository and Forks opens its fork list. `src/scripts/github.js` requests the public
repository API once per page load, without credentials or a referrer, and formats
valid counts for the page language. There is no polling, token, or new dependency.
If the request fails or GitHub rate-limits it, both links remain usable and the
numeric counts stay hidden. Values are never fabricated or seeded with zero.

## Native interface visuals

The landing page shows actual production `SettingsView` (Layout tab) and
`DropdownView`, rendered through SwiftUI/AppKit on macOS with deterministic
sample data. These are native view snapshots, not desktop screenshots or an
HTML/CSS recreation. No personal desktop, application inventory, or user
preferences are included. The page itself does not simulate app interactions.

Four reusable full-resolution PNGs live in `public/assets/native-ui/`:

- `settings-light.png` and `settings-dark.png`: 1640 × 1356, the actual Settings
  window and native titlebar at 2× scale.
- `dropdown-light.png` and `dropdown-dark.png`: 784 × 248, the actual DropdownView
  content at 4× scale, without fabricated popover chrome.

Each image links to its full-resolution PNG, with a localized full-size label
and descriptive alt text. Light/dark pairs follow the page’s system or manual
theme through the existing stylesheets, including without JavaScript. The app
interface remains English on both language pages.

Regenerate from the repository root on macOS:

```sh
Scripts/snapshot-website.sh
```

The assets show version 1.0.0, build 1, rendered on macOS 15.7.1.
`public/assets/native-ui/provenance.json` records view source hashes, dimensions,
scale, and fixture details. The exporter uses the app’s current production views
and isolated synthetic fixtures. It does not discover or move real menu-bar items, capture the desktop,
or request Screen Recording or Accessibility permission. Native rendering and
system controls can vary between macOS versions; regenerate all four files
together. Keep logs and capture notes under ignored `.build/` or outside the
repository.

## Installation commands

The documented two-line Homebrew command appears directly beneath the native
images and in the installation FAQ, using `src/components/HomebrewCommands.astro`.
Each instance has its own copy icon with a localized accessible label. Successful
copying briefly shows a checkmark and resets after 2.5 seconds. Icon feedback
crossfades without changing layout and respects reduced motion.
`src/scripts/clipboard.js` copies the code as displayed; if clipboard access is
blocked, it selects the code for manual copying. Localized results are announced
to screen readers without adding visible text. Without JavaScript, the commands
remain selectable and the copy button stays hidden. The website never executes
Homebrew commands.

## Assets and copy

App artwork and favicon derivatives use [Support/AppIcon.png](../Support/AppIcon.png).
The English and Russian 1200 × 630 social cards use the same artwork and warm palette.
Website navigation icons use Tabler Icons v3.35.0 under the
[bundled MIT notice](public/assets/tabler-LICENSE.txt).
Native interface visuals come from [Views.swift](../Sources/TrayNook/Views.swift)
and [LayoutPreviewView.swift](../Sources/TrayNook/LayoutPreviewView.swift), with
sanitized fixtures supplied by the native snapshot exporter.

Copy was checked against README, CHANGELOG, RELEASING, and current app code.
Visible copy describes the product in the present tense and contains no release
plans. On 2026-11-09 the public Releases page had no published releases and the
tap cask returned 404. The CTA remains **View on GitHub**. The copyable Homebrew
commands are included at the owner's request for the release-ready page; the tap
repository exists, and its first cask depends on the first stable release.
Reverify public assets and cask installation before publishing the website.

## Verification

- `npm --prefix website run build` produces the three static language routes.
- `npm --prefix website test` covers language detection, translation consistency,
  native image descriptions, theme preferences, GitHub counts, and clipboard
  feedback, including failures and independent copy controls.
- `python3 website/check.py` validates all four PNG headers and dimensions,
  render-provenance hashes, full-size asset links, both themes, removal of the
  recreated interface, local
  links/assets, ARIA references, language routes, canonical/social metadata,
  GitHub controls, and both Homebrew command blocks.
- EN/RU browser checks at 320, 390, 768, and 1440 CSS pixels passed: images fit,
  full-size links receive visible keyboard focus, system/manual themes select
  the matching native PNGs, and installation copying still works. Without
  product JavaScript, native images follow the system theme and remain linked.
  Surrounding text passes contrast checks; reduced-motion CSS disables transitions
  and smooth scrolling. Repeat these checks after changing the presentation.

Safari, Firefox, VoiceOver, physical touch devices, and live social unfurls have
not been manually verified. Image links work without JavaScript; viewing a PNG
never opens the native app or changes Mac preferences.

## Before publishing

The site source stays in this repository's `website/` directory. Build and publish
`website/dist/` to GitHub Pages at `https://traynook.mahenzon.ru/`; the source directory
itself is not the publishable output. `public/.nojekyll` is copied into the build
so branch-based Pages publishing preserves Astro's `_astro/` assets.

Astro's `site`, canonical links, `og:url`, language alternates, and social image
URLs use that HTTPS domain. `public/CNAME` also copies it into the build for
branch-based Pages publishing. The offline validator checks these URLs and
resolves same-domain references against the built files.

1. In the repository's **Settings → Pages**, configure the custom domain as
   `traynook.mahenzon.ru`.
2. In DNS for `mahenzon.ru`, point the `traynook` CNAME record to
   `traynook.github.io` (the GitHub organization, without a repository path).
3. Enable **Enforce HTTPS** once Pages has issued its certificate. Recheck
   release/tap availability and live page links before publishing.

The native exporter uses injected icon data and disables saved status-item
positions for its fixture; the application's default behavior is unchanged.
No Pages workflow, deployment, version tags, or app releases are included.
