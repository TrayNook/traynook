# Naming research

Research date: 22 July 2026.  
Selected product name: **TrayNook**, pending the final clearance steps below.

## Naming criteria

The product name should be:

- short, pronounceable, and easy to type;
- not another variation of Hidden, Ice, Bartender, Barbee, or Tuck;
- broad enough to survive a new app icon without implying collapse or automation;
- usable as an application name, GitHub repository slug, Homebrew cask token, and bundle-name component;
- reasonably searchable without claiming legal availability.

## Shortlist

Preliminary screening used each candidate as an exact quoted string on general web search; exact repository-name searches on [GitHub](https://github.com/search?type=repositories); web results from the US and Russian Mac App Store storefronts; the [Homebrew cask index](https://formulae.brew.sh/cask/); and the [Mac Menubar Megalist](https://github.com/SKaplanOfficial/Mac-Menubar-Megalist). No exact macOS-app/software collision was found for the first four names on those screened surfaces. Search results are time- and locale-dependent, so the date and queries must be repeated before naming lock.

| Candidate | Strength | Concern |
| --- | --- | --- |
| **TrayNook** | Friendly, short, and evokes a small reserved place | “Tray” is more common on Windows/Linux than Apple's “menu bar”; one incidental [interior-plan phrase](https://www.eplans.com/plan/1945-square-feet-2-bedroom-2-50-bathroom-3-garage-sp165627) appears in general search |
| **IconAnnex** | Describes an additional home for icons without implying hiding | Slightly technical and longer when spoken |
| **TrayAnnex** | Clear second-space metaphor and clean preliminary search | Same non-Mac “tray” terminology; less warm than TrayNook |
| **StatusAnnex** | Technically precise and clean preliminary search | Sounds infrastructural rather than like a small Mac app |
| **Elsebar** | Short, memorable, and communicates “the other bar” | Unrelated venue/user-name uses weaken search ownership |

## Decision

**TrayNook** is the selected name. It is friendly, short, and evokes a small reserved place for items. Its use of “tray” is less Mac-specific than “menu bar,” but the distinctiveness and warmer identity were preferred over the more technical **IconAnnex**.

The canonical GitHub organization is **TrayNook**, with `github.com/TrayNook/traynook` as the intended public repository. Reservation and final release-surface clearance remain future release tasks.

The permanent reverse-DNS bundle identifier is **`io.github.mahenzon.TrayNook`**. It must not change after permission-bearing preview builds are distributed.

The initial Homebrew surface is `github.com/TrayNook/homebrew-tap` with cask token `traynook`, yielding `brew install --cask traynook/tap/traynook`.

The selected visual metaphor is a simple open tray or pocket containing three dots. It serves as a monochrome template mark in the Menu Bar and as the basis for a later colored Finder/Settings app icon.

The technical release identity—the intended repository, bundle identifier, and Homebrew token—is selected and must not drift during implementation. Selection does not mean the repositories have been reserved or that the name has completed legal and release-surface clearance; those remain release gates below.

A fresh exact-name search after selection found no obvious macOS application, GitHub project, or Homebrew cask collision. The visible general-web collision remains an unrelated house-plan phrase, so this is a discoverability result rather than trademark clearance.

## Rejected names

- **MenuNook** — existing [MenuNook](https://www.menunook.com/) product
- **MenuLoft** — existing [MenuLoft](https://www.menuloft.app/) product
- **Stowlet** — existing [Stowlet](https://ayohi.com/stowlet) app
- **DropShelf** — existing [DropShelf](https://pilotmoon.com/dropshelf/) macOS app
- **MenuStow** — existing [MenuStow](https://www.menustow.com/) menu-bar product
- **ExtraBar** — existing [ExtraBar](https://extrabar.app/) macOS product
- **Tuck** — direct [Tuck](https://usetuck.com/) competitor
- **Traylet** — older unrelated software/component and patent uses make it less clean
- **MenuPocket**, **BarPocket**, **MenuShelf**, and **BarDrawer** — descriptive but crowded generic phrases and weaker search ownership

## Before releasing the name

Preliminary discoverability screening is not trademark or company-name clearance. Once one candidate is preferred:

1. Search relevant national and international trademark registries for exact and confusingly similar names.
2. Recheck the Mac App Store, GitHub, Homebrew, package indexes, company registries, and general search on the decision date.
3. Check domains and social handles if the project wants them; a domain is optional for this app.
4. Reserve the GitHub repository; select and validate the token in the owner-maintained Homebrew tap. An official Homebrew cask token is not independently reservable.
5. Choose a stable reverse-DNS bundle identifier and do not change it after users grant Accessibility permission.
6. Confirm the intended signing owner can use the name.

If clearance discovers a material conflict, return to the shortlist rather than silently changing the release identity.
