<div align="center">
  <h1>Marjenoti</h1>
  <p>Notes in the right margin.</p>
  <p>by <a href="https://sypian.ski/">Jakub Sypiański</a> · License: AGPL-3.0</p>
  <p>Updated 24 July 2026</p>

  [![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
  ![Platform](https://img.shields.io/badge/platform-KOReader-brightgreen)
</div>

> **Part of the KOReader family.** Related apps:
> [Rosetta](https://github.com/sypianski/rosetta.koplugin), a translation under the book text;
> [Hairline](https://github.com/sypianski/hairline.koplugin), a thin progress bar at the bottom edge;
> [KoTheme](https://github.com/sypianski/kotheme.koplugin), rounded corners and thinner borders;
> and others.

A [KOReader](https://github.com/koreader/koreader) plugin that renders annotation notes in the **right page margin**, beside their highlights, like glosses in a critical edition.

> *Marjenoti* — Esperanto compound: *marĝeno* (margin) + *noto* (note).

KOReader's default annotation UI hides notes behind a tap-and-popup. *Marjenoti* makes them part of the page itself: every highlighted passage with a note attached gets a small text box pinned to its top edge, stacked along the right margin without overlapping, separated from the body text by a thin "L"-shaped rule.

Reads like a critical edition or a marginalia-rich philosophy paperback.

## Install

Clone the repository (it is the plugin directory) into KOReader's `plugins/` folder under the name `marjenoti.koplugin`:

```sh
git clone https://github.com/sypianski/marjenoti.koplugin \
    ~/.config/koreader/plugins/marjenoti.koplugin
```

The path above is for native Linux. On other systems use the plugins folder of your KOReader:

| Platform | Plugins folder |
|---|---|
| Linux (native) | `~/.config/koreader/plugins/` |
| Linux (Flatpak) | `~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/` |
| Kobo / Kindle / PocketBook | `koreader/plugins/` on the device |
| Android | `koreader/plugins/` in KOReader's storage folder |

Instead of cloning you can download the repository as a ZIP from GitHub and unpack it into the plugins folder; the folder must be named `marjenoti.koplugin`.

Restart KOReader. The plugin attaches itself automatically; *Tools > Marjenoti* opens font controls.

There are no prebuilt releases; the repository is the distribution.

## What it does

Just read. Any annotation note (added via KOReader's normal highlight → note flow) appears in the right margin. No keys, no menu actions required for the feature itself.

Font and font size adjust under *Tools → Marjenoti*. The plugin picks the best available serif at startup (Literata → Bookerly → Brill → Cardo → Crimson Pro → … → DejaVu Serif → infofont).

## Technical notes

### How it works

- Hooks into KOReader's view-module system (`paintTo`) so it draws on every page render
- Pre-computes positions during `_update_items()` using each annotation's `pos0`/`pos1` xpointers — survives reflow, font changes, margin tweaks
- Walks the page's visible words (via the bundled `paginmapo.lua` extractor) to find the **real right edge of the text block**, not the screen edge — so a short mid-line highlight does not pull a note into the running text
- Falls back to a 78%-of-screen heuristic when `paginmapo` is unavailable or the document is paged (PDF)
- Stacks notes vertically without overlap (each item carries its own `y_top` + height)

### Integration with visel (pluginaro)

Marjenoti registers itself as an extension provider with `pluginaro`, the
shared cross-plugin registry (`pluginaro.lua`, also vendored here). If the
`visel` plugin is installed, its **N** key jumps between margin notes on the
current page: visel owns the key binding, marjenoti supplies the list of
note-carrying annotation xpointers via `Pluginaro.register("visel", { id =
"note_jump", ... get_targets = ... })` (see `main.lua`). The extension is
opt-in and disabled by default — enable it from visel's own extensions menu.
Without visel installed, marjenoti behaves exactly as described above; the
integration is inert.

### Bundled `paginmapo.lua`

This plugin vendors `paginmapo.lua` (Ido for "page-map") — a 411-line CRengine helper that extracts visible words with screen positions and xpointer anchors. It is also used by the sibling plugins keyreader, kopad, and assistant. Each ships its own copy so they remain runtime-independent.

If you maintain a fork or copy and edit `paginmapo.lua` here, please keep it identical to the upstream copies in the related plugins.

### Compatibility

Tested with KOReader 2026.03 on desktop Linux. Reflowable docs (EPUB, FB2, …) get the precise text-block-edge layout; paged docs (PDF) get the 78% heuristic.

## How this was made

Marjenoti was written largely by Claude, working from my specifications and
under my direction ("vibe coding"). I reviewed and tested the results, but
the code has not had an independent audit. Treat it as you would any young
project and report what you find.

## Feedback

Marjenoti is a young project. If something breaks, behaves oddly or is missing, tell me:

<!-- feedback-form: https://sypian.ski/uwagi/?app=marjenoti -->
- [Open an issue on GitHub](https://github.com/sypianski/marjenoti.koplugin/issues/new). Bug reports, ideas and questions are all fine there; include your KOReader version, your device and, if possible, the book format.
- Or email jakub.sypianski@gmail.com.

## Support

Marjenoti is free. If it is useful to you, you can [buy me a coffee on Ko-fi](https://ko-fi.com/sypianski).

## License and credits

Marjenoti is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0), see [LICENSE](LICENSE).

Marjenoti matches KOReader's license. It vendors `paginmapo.lua` and `pluginaro.lua`, small helpers shared with the sibling plugins (see Technical notes).

---

<p align="center">Marjenoti · <a href="https://sypian.ski/">Jakub Sypiański</a> · AGPL-3.0</p>
