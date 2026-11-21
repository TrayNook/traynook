# TrayNook landing page

The static Astro site lets visitors try TrayNook’s dropdown, arrange four icons, and find the install path available today. It uses local assets, system fonts, and plain browser JavaScript.

## Develop and verify

Use Node.js 22.23.4 or later and npm 9.6.5 or later. Run these commands from the repository root.

```sh
npm --prefix website ci
npm --prefix website run dev
```

Open <http://localhost:4173>. If the port is busy, pass `-- --port 4180` to the dev command. Press **Ctrl+C** to stop it.

```sh
npm --prefix website run build
npm --prefix website test
python3 website/check.py
```

The Node tests cover language selection, translations, appearance preferences, GitHub counts, and the copy buttons. The offline checker inspects all three built pages, their links and metadata, accessible labels, the original screenshot, and the installation instructions. Check the page at narrow and wide widths and with keyboard navigation after presentation changes.

## Page and preferences

- Edit the shared layout in `src/components/Landing.astro` and the English and Russian copy in `src/i18n/`. The native app currently ships in English. Keep its controls recognizable in Russian instructions.
- `/en/` and `/ru/` serve their chosen language. At `/`, a saved language choice takes priority over the browser's supported language, with English as the fallback. Without JavaScript, the root serves English and the language links still work.
- The appearance selector follows the system by default. Light and Dark persist in `traynook.theme` when storage is available. Without JavaScript, presentation follows the system through CSS.
- The header groups the GitHub repository link with Stars and Forks. Counts come from a single unauthenticated GitHub API request per page load. The links stay usable when the request fails.

## Product images

The owner supplied the two original PNGs in `public/assets/native-ui/`. The 532 × 234 dropdown shows the launcher, gear and four app icons. The 1597 × 2000 Settings capture shows the complete Layout window. Both languages and appearances use the same files. Dimensions and original file hashes are recorded in [provenance.json](public/assets/native-ui/provenance.json).

The example starts with the open dropdown. The tray toggles it. The gear shows the native Layout window, with an option to practice moving and reordering icons by dragging or using buttons. After each edit, the dropdown preview uses pixels from the actual screenshot. Choosing an app explains how macOS opens its menu. Without JavaScript, visitors can access both screenshots at their original resolution.

The app icon and favicon derivatives come from [Support/AppIcon.png](../Support/AppIcon.png). The localized 1200 × 630 social cards use the same artwork. Navigation icons are Tabler Icons v3.35.0, distributed under their [MIT notice](public/assets/tabler-LICENSE.txt).

## Installation status

On November 21, 2026, GitHub listed no published release and the public tap had no TrayNook cask. The install section sends visitors to the [source build instructions](https://github.com/TrayNook/traynook#build-from-source).

The install section and FAQ share `src/components/HomebrewCommands.astro`. Each includes the owner's two-line command, a localized availability note, and a copy button. If clipboard permission is denied, the page selects the command for manual copying. With JavaScript off, visitors can still select the text.

When the first release ships, verify the public download and both Homebrew commands on a clean Mac. Update the install copy in both locales once the public cask works.

## Publishing

The configured GitHub Pages target is <https://traynook.mahenzon.ru/>. Astro builds the custom domain into canonical links, language alternates, and social metadata. It also copies `public/CNAME` and `public/.nojekyll` into its output so branch-based Pages publishing preserves the domain and `_astro/` assets.

1. Build the site and publish `website/dist/` as the Pages output.
2. Configure `traynook.mahenzon.ru` in the repository's **Settings → Pages**. Point the `traynook` CNAME in the `mahenzon.ru` DNS zone to `traynook.github.io`.
3. Enable **Enforce HTTPS** once Pages issues the certificate. Check both locale routes, the installation links, and a social preview against the public domain.
