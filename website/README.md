# TrayNook landing page

A static Astro page with system fonts, a warm palette drawn from the canonical
icon, and a real user-provided screenshot of TrayNook’s dropdown.
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

## Real interface screenshot

`public/assets/native-ui/dropdown.png` is the original screenshot supplied by
the user: 438 × 242 pixels. It shows the real TrayNook dropdown, native arrow,
and menu bar. The image is unchanged; the page does not recreate its controls,
replace its app icons, recolor it, or invent a dark variant. It displays at no
more than 438 CSS pixels wide and links to the original PNG in both page themes.
The full-size link and descriptive alt text are localized in English and Russian.

`public/assets/native-ui/provenance.json` records the source, original dimensions,
and SHA-256 hash. The captured app version and build are unknown. No larger
original or separate Settings screenshot was supplied, and no exporter is used
to generate replacements. The page does not simulate app interactions or identify
the three applications shown in the screenshot.

Keep capture notes and reports under ignored `.build/` or outside the repository.

## Installation commands

The documented two-line Homebrew command appears directly beneath the screenshot
and in the installation FAQ, using `src/components/HomebrewCommands.astro`.
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
The real interface screenshot is supplied by the user and preserved as received.

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
  screenshot descriptions, theme preferences, GitHub counts, and clipboard
  feedback, including failures and independent copy controls.
- `python3 website/check.py` checks the original PNG header, 438 × 242 dimensions,
  provenance hash, full-size link, removal of synthetic interface assets and
  scripts, local links/assets, ARIA references, language routes, canonical/social
  metadata, GitHub controls, and both Homebrew command blocks.
- Repeat browser layout, focus, theme, and reduced-motion checks after changing
  the screenshot or presentation. Both page themes must keep the same original
  image without filters, enlargement, or hidden alternatives.

Safari, Firefox, VoiceOver, physical touch devices, and live social unfurls have
not been manually verified. The screenshot and its full-size link work without
JavaScript and never open the native app or change Mac preferences.

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

No Pages workflow, deployment, version tags, or app releases are included.
