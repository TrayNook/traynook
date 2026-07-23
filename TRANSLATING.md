# Translating TrayNook

TrayNook 1.0.0 ships in US English. Community translations are welcome once the application target and its string catalog exist.

## Translation principles

- **TrayNook** is a product name and is not translated.
- Translate complete user-facing messages, not fragments assembled in code.
- Preserve placeholders and their types. Use the translator comments beside each entry to understand where and how the string appears.
- Use the target language's plural, grammatical, punctuation, capitalization, and menu conventions rather than translating word-for-word.
- Do not translate technical identifiers, bundle identifiers, file names, keyboard symbols, or code.
- Keep permission explanations precise: translations must not promise access or behavior beyond the English source text.

## Adding or updating a language

1. Fork the repository and use the current stable Xcode version documented for the project.
2. Add or select the language in TrayNook's Xcode String Catalog (`Localizable.xcstrings`) after that application resource exists.
3. Translate every entry marked for localization and preserve all placeholders.
4. Build and inspect Settings, onboarding, permission states, the Launcher menu, the Dropdown, errors, and recovery actions at narrow and wide window sizes.
5. Run the project checks documented in the repository and open a pull request describing the locale and what was manually verified.

Do not edit generated build output or introduce a parallel translation file format.

## Right-to-left languages

For Arabic, Hebrew, Persian, Urdu, and other right-to-left languages:

- verify natural macOS mirroring rather than manually reversing arrays or text;
- verify Placement Lanes, Dropdown Rows, drag destinations, menus, sliders, icons, mixed-direction text, numbers, and keyboard focus order;
- keep inherently directional symbols correct; a direction-sensitive icon must mirror only when its meaning should mirror;
- test long translations and mixed app names that remain left-to-right;
- test using Xcode's right-to-left pseudolanguage before requesting review by a native speaker.

## Review expectations

A translation pull request should identify the locale, name a native-language reviewer when possible, and confirm that placeholders, truncation, Menu Bar terminology, permission explanations, and RTL behavior were checked. Maintainers may update translations when the US English source changes; incomplete locales may be withheld from a release rather than shipping misleading text.
