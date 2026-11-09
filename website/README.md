# TrayNook landing page

A static Astro page with system fonts, a warm palette drawn from the canonical
icon, and an interactive browser recreation of the native dropdown. Astro is
the only direct build dependency; the page uses plain browser JavaScript.
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
`ASTRO_TELEMETRY_DISABLED=1 npx astro preview stop`. Hosting is GitHub Pages with
a custom domain; the domain and deployment are not configured yet. The npm
scripts disable Astro telemetry.

## Languages

- `/` serves English HTML, then selects the first supported browser language.
  Regional tags such as `ru-RU` and `en-GB` are supported; the fallback is English.
- `/en/` and `/ru/` always show their requested language without redirecting.
  The header's EN/RU links save an explicit choice in `traynook.language` in
  local storage. That choice takes priority when revisiting `/`.
- If storage is blocked, language links and browser detection still work. If
  JavaScript is disabled, `/` stays English and both language links still work.
- Copy lives in `src/i18n/en.json` and `src/i18n/ru.json`; the shared layout is
  `src/components/Landing.astro`. Metadata, demo messages, accessibility labels,
  and social images are localized. The native app currently uses English, so
  its interface labels stay English in the demonstration and instructions.

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

## Try the demo

The documented two-line Homebrew command appears directly beneath the demo and
in the installation FAQ, using `src/components/HomebrewCommands.astro`. Each
instance has its own copy icon with a localized accessible label. Successful
copying briefly shows a checkmark and resets after 2.5 seconds. Icon feedback
crossfades without changing layout, and respects reduced motion.
`src/scripts/clipboard.js` copies the code as displayed;
if clipboard access is blocked, it selects the code for manual copying.
Localized results are announced to screen readers without adding visible text.
Without JavaScript, the commands remain selectable and the
copy button stays hidden. The website never executes Homebrew commands.

- Click the monochrome tray to toggle the dropdown. Keyboard opening focuses
  Settings; Escape and clicking elsewhere inside the demo dismiss it. Clicks
  outside the demo leave it open.
- The first gear opens the separate **Settings → Layout** example. Drag icons
  between groups or onto another icon to reorder. Alternatively, select an icon
  and choose a group; this works with touch and keyboard.
- Clicking a dropdown icon demonstrates the temporary menu-bar reveal and
  explains the app's native-menu handoff. It does not invent a source-app menu.
- **Reset demo** restores the example. Changes stay in memory and reset on reload;
  the real Mac app saves layouts automatically.

The compact 240 × 62 initial popover follows `DropdownView` / `DropdownIcons` in
[Views.swift](../Sources/TrayNook/Views.swift): 36-point columns, 8-point gaps,
26-point app icons, borderless controls, gear first, no title or normal footer.
The menu-bar launcher and dismissal behavior follow
[TrayNookApp.swift](../Sources/TrayNook/TrayNookApp.swift). Dragging belongs in
[LayoutPreviewView](../Sources/TrayNook/LayoutPreviewView.swift).

## Assets and copy

App artwork and favicon derivatives use [Support/AppIcon.png](../Support/AppIcon.png).
The English and Russian 1200 × 630 social cards use the same artwork and warm palette.
Generic sample icons use Tabler Icons v3.35.0 under the
[bundled MIT notice](public/assets/tabler-LICENSE.txt).
The visible caption identifies the interactive demo and explains where to drag icons.
AppKit material and exact appearance vary by macOS; this is not a screenshot.
The original CSS wallpaper keeps the icon's warm palette. Popovers and window
chrome approximate native materials with blur, fine borders, and inset highlights;
solid surfaces remain available without blur support or with reduced transparency.
The red window control closes the example; the other two lights are decorative
disabled controls, hidden from assistive technology.

Copy was checked against README, CHANGELOG, RELEASING, and current app code.
Visible copy describes the product in the present tense and contains no release
plans. On 2026-11-09 the public Releases page had no published releases and the
tap cask returned 404. The CTA remains **View on GitHub**. The copyable Homebrew
commands are included at the owner's request for the release-ready page; the tap
repository exists, and its first cask depends on the first stable release.
Reverify public assets and cask installation before publishing the website.

## Verification

- Layouts at 320, 375, 390, 768, 1024, and 1440 CSS pixels: no horizontal overflow;
  the Settings example fits its container. Desktop/mobile visuals inspected.
- Actual browser clicks, keyboard opening/focus, Escape, temporary reveal/return,
  drag/drop, click-to-move, selection cancellation, empty state, and reset passed.
- Thirty-six Node tests cover demo state, language fallback/preference order,
  regional tags, translation consistency, theme preferences, and repository
  counts, formatting, response validation, request failures, and clipboard copying.
  The offline validator checks all three built pages, local assets/links, ARIA
  references, locale routes, social metadata, and theme controls.
- Browser checks passed for automatic language selection, saved preference,
  blocked storage, and keyboard language switching. Russian layouts at 320,
  390, 768, and 1440 CSS pixels fit without horizontal overflow.
- axe-core 4.10.3 (WCAG 2 A/AA, 2.1 AA, 2.2 AA, best practices): zero violations
  or incomplete checks in light/dark styling, including Settings and expanded FAQ.
  Reduced-motion styles compute to no transitions and no smooth scrolling.
- Preference-rule bodies were activated through CSSOM for browser checks. Visual
  rendering also covered light/dark appearance. Audit tooling is not shipped.

Safari, Firefox, VoiceOver, physical touch devices, and live social unfurls remain
untested. The demo opens no native apps or windows and changes no Mac preferences.

## Before publishing

The site source stays in this repository's `website/` directory. Build and publish
`website/dist/` to GitHub Pages at the custom domain's root; the source directory
itself is not the publishable output. `public/.nojekyll` is copied into the build
so branch-based Pages publishing preserves Astro's `_astro/` assets.

Once the domain is chosen, set Astro's `site` URL, add the canonical link and
`og:url`, and replace relative `og:image` / `twitter:image` paths with the absolute
HTTPS URL of the bundled social card. Configure that domain in Pages and its DNS,
then recheck release/tap availability and page links before publishing.
No Pages workflow, deployment, version tags, app releases, or application-source
edits are included.
