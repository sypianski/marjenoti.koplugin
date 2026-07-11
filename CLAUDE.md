# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`marjenoti` is a **KOReader plugin** (pure Lua, no build step) that renders
annotation notes in the right page margin next to their highlights — like
glosses in a critical edition. *Marjenoti* = Esperanto *marĝeno* (margin) +
*noto* (note).

There is no compiler, package manager, linter config, or test suite in this
repo. "Running" means loading the plugin inside a KOReader install; all
`require(...)` targets (`ui/widget/...`, `datastorage`, `device`, …) resolve
against KOReader's runtime, not anything vendored here. You cannot execute
these files standalone.

## Files

| File | Role |
|---|---|
| `main.lua` | The plugin. `MarginNotes = Widget:extend{...}`, registered as a KOReader **view module**. |
| `_meta.lua` | Plugin manifest (name / fullname / description) KOReader reads to list the plugin. |
| `paginmapo.lua` | Vendored CRengine word/sentence extractor. Only `collect_words` is used here. |
| `README.md` | User-facing install/usage. |

## Deploy / test loop

The repo root **is** the plugin's contents, but KOReader expects them inside a
directory named `marjenoti.koplugin/`. To test a change, copy or symlink the
repo into KOReader's `plugins/` dir under that name, then restart KOReader:

```
~/.config/koreader/plugins/marjenoti.koplugin/         # Linux native
~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/marjenoti.koplugin/   # Flatpak
```

There is no automated test — verification is manual: open a reflowable doc
(EPUB/FB2) that has annotation notes and confirm the margin boxes render,
stack without overlap, and survive font-size / reflow changes. Font controls
live under *Tools → Marjenoti*.

## Architecture — the two-phase rule (critical)

KOReader repaints on every page render. The plugin obeys a hard split:

1. **`_update_items()`** — the only place allowed to call document APIs
   (`doc:getScreenBoxesFromPositions`, `paginmapo.collect_words`). It runs on
   `onReaderReady`, `onPageUpdate`, `onPosUpdate`, `onUpdatePos`,
   `onAnnotationsModified`. It walks `ui.annotation.annotations`, keeps only
   entries with a non-empty `note` plus `pos0`/`pos1`, resolves each to screen
   boxes, and precomputes `y_top` + box height into `self._items`.

2. **`paintTo(bb, x, y)`** — pure drawing, **no doc API calls**. Reads the
   cached `self._items` / `self._nx` / `self._note_w` and blits rectangles +
   text. Keeping doc calls out of `paintTo` is what keeps rendering fast and
   avoids re-entrancy against CRengine during a paint.

If you add behavior, respect this boundary: anything that queries the document
belongs in `_update_items` (or a helper it calls), never in `paintTo`.

## Margin-edge detection

The notes pin to the **right edge of the text block**, not the screen edge, so
a short mid-line highlight doesn't drag a note into the running text.
`_text_block_right()`:

- Reflowable docs (`doc.info.has_pages == false`): `paginmapo.collect_words`
  returns visible words with screen boxes; the max `sbox.x + sbox.w` is the
  real text-block right edge. This mirrors sibling-plugin `vortuyo`'s
  `min_x_left` logic on the opposite margin.
- Paged docs (PDF) or if `paginmapo` fails to load: falls back to
  `floor(sw * 0.78)`.

## `paginmapo.lua` is vendored, shared code

This file is a verbatim copy shared with sibling plugins (keyreader, kopad,
assistant). Each plugin ships its own copy to stay runtime-independent. **If
you edit `paginmapo.lua` here, keep it byte-identical to the upstream copies** —
diverging it silently breaks the shared contract. Prefer fixing it upstream and
re-vendoring. Most `marjenoti` work touches only `main.lua`.

## Fonts & settings

- Best-serif autodetection at module load walks a priority list
  (`Literata → Bookerly → Brill → … → DejaVu Serif → infofont`) via
  `Font:getFace`, wrapped in `pcall`. First that loads wins.
- User overrides persist to `<SettingsDir>/marjenoti.lua` via `LuaSettings`
  (`font_name`, `font_size`). Changing either calls `_apply_font()` (which
  invalidates the cached `_line_h`) then `_update_items()` then marks the view
  dirty.

## License

AGPL-3.0, matching KOReader. Keep new files compatible.
