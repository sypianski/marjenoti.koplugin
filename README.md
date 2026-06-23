# koreader-marjenoti

A [KOReader](https://github.com/koreader/koreader) plugin that renders annotation notes in the **right page margin**, beside their highlights, like glosses in a critical edition.

> *Marjenoti* — Esperanto compound: *marĝeno* (margin) + *noto* (note).

## Why

KOReader's default annotation UI hides notes behind a tap-and-popup. *Marjenoti* makes them part of the page itself: every highlighted passage with a note attached gets a small text box pinned to its top edge, stacked along the right margin without overlapping, separated from the body text by a thin "L"-shaped rule.

Reads like a critical edition or a marginalia-rich philosophy paperback.

## Install

Drop `marjenoti.koplugin/` into KOReader's `plugins/` directory:

| Platform | Path |
|---|---|
| Linux (native) | `~/.config/koreader/plugins/` |
| Linux (Flatpak) | `~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/` |
| Kobo / Kindle / PocketBook | `koreader/plugins/` on the device |
| Android | `koreader/plugins/` in KOReader's storage folder |

Restart KOReader. The plugin attaches itself automatically; *Tools → Marjenoti* opens font controls.

## Use

Just read. Any annotation note (added via KOReader's normal highlight → note flow) appears in the right margin. No keys, no menu actions required for the feature itself.

Font and font size adjust under *Tools → Marjenoti*. The plugin picks the best available serif at startup (Literata → Bookerly → Brill → Cardo → Crimson Pro → … → DejaVu Serif → infofont).

## How it works

- Hooks into KOReader's view-module system (`paintTo`) so it draws on every page render
- Pre-computes positions during `_update_items()` using each annotation's `pos0`/`pos1` xpointers — survives reflow, font changes, margin tweaks
- Walks the page's visible words (via the bundled `paginmapo.lua` extractor) to find the **real right edge of the text block**, not the screen edge — so a short mid-line highlight does not pull a note into the running text
- Falls back to a 78%-of-screen heuristic when `paginmapo` is unavailable or the document is paged (PDF)
- Stacks notes vertically without overlap (each item carries its own `y_top` + height)

## Bundled `paginmapo.lua`

This plugin vendors `paginmapo.lua` (Ido for "page-map") — a 411-line CRengine helper that extracts visible words with screen positions and xpointer anchors. It is also used by the sibling plugins keyreader, kopad, and assistant. Each ships its own copy so they remain runtime-independent.

If you maintain a fork or copy and edit `paginmapo.lua` here, please keep it identical to the upstream copies in the related plugins.

## Compatibility

Tested with KOReader 2026.03 on desktop Linux. Reflowable docs (EPUB, FB2, …) get the precise text-block-edge layout; paged docs (PDF) get the 78% heuristic.

## License

[AGPL-3.0](LICENSE). Matches KOReader.
