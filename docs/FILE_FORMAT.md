# ActionNotes markdown format

Every project is one markdown file in the repo under `projects/`, and images
attached to notes live under `attachments/`.

```
projects/
  groceries.md
  house-move.md
attachments/
  house-move/
    door.png
```

The project filename is a slug of the title. It never changes after creation,
even if the title is edited — the title lives in the front matter.

## File anatomy

```markdown
---
title: House move
created: 2026-09-15T09:12:44Z
updated: 2026-09-16T18:30:02Z
---

# House move

- [ ] ⭐ Book the van
  Rang Omar, waiting on sizes.

  ![door detail](../attachments/house-move/door.png)
- [x] Cancel broadband
- [ ] Redirect post

Landlord's number is in the drawer.
```

Four parts, in this order:

1. **Front matter** — a `---` fenced block of `key: value` lines. Keys:
   - `title` (required) — display name of the project.
   - `created` / `updated` — UTC ISO-8601 timestamps, maintained by the app.
   - Unknown keys are preserved verbatim on write, so you can add your own.
2. **Heading** — a single `# Title` line mirroring the front-matter title, so the
   file reads well on GitHub and when pasted into a chat. Optional on read.
3. **Items** — the checklist. See below.
4. **Project notes** — any unindented free text after the items.

## Items

```markdown
- [ ] An open item
- [x] A completed item
- [ ] ⭐ A starred item
- [ ] An item with notes
  Any markdown, indented two spaces.

  Including a blank line, and images:
  ![alt](../attachments/<project-slug>/<file>)
```

- `- [ ]` is open, `- [x]` is done. **A project's items sit at the left
  margin.** An indented `- [ ]` belongs to the note above it, which is what
  lets a note hold a checklist of its own without those rows being read as
  more items of the project.
- A **⭐ before the text** marks the item starred — the app's equivalent of
  Microsoft To Do's star. It is stripped from the displayed text.
- **Lines indented by two spaces** after an item are that item's notes. The
  indent is what distinguishes a note from the next item, so an indented `-`
  is a bullet inside a note rather than a new item.
- A blank line inside a note block is kept, so notes can have paragraphs.
- The first unindented line after a note block ends it.

The app draws starred items above the other open ones, but pinning is a view,
not a rewrite: the file keeps the order you gave it.

Item order in the file is the item order in the app. The app displays open
items first and groups completed ones under a collapsible header, but it does
not rewrite the file to match that view: reordering in the app moves open items
among themselves and leaves completed items where they are.

## Attachments

Images are stored in the repo at `attachments/<project-slug>/<filename>` and
referenced from notes **relatively** as
`../attachments/<project-slug>/<filename>`. The relative form matters: it is
what makes GitHub render the image when you view `projects/<slug>.md` in the
browser.

Images are re-encoded to PNG on the way in unless they already carry a sound
format. This matters for pasting: the Windows clipboard hands over a
device-independent bitmap, so a paste would otherwise store a multi-megabyte
BMP under a `.png` name — which GitHub and Obsidian both refuse to render,
since they go by the extension, and which appears upside down because a BMP's
rows run bottom-up.

Because the repo is usually private, the app cannot load these images by URL.
It fetches them through the API and caches them on the device, so a note opened
once renders offline afterwards.

## Rules the parser follows

- Reading is forgiving: missing front matter, a missing heading, `*` instead of
  `-`, `[X]` instead of `[x]`, `★` instead of `⭐`, and tab-indented notes all
  parse fine.
- Writing is canonical: the app always emits the shape shown above, so diffs
  stay small and reviewable.
- Anything the app does not understand in the front matter is round-tripped
  unchanged rather than dropped.

## What the note editor understands

Notes are edited as blocks, and these are the line kinds it models:

| Markdown | Editor |
| --- | --- |
| `# ` to `###### ` | heading, drawn at size with the hashes hidden |
| `- ` | bullet, drawn with a dot |
| `- [ ] ` / `- [x] ` | a checklist row with a real checkbox |
| `![alt](path)` alone on a line | the image itself |
| `---`, `***` or `___` | a horizontal rule |
| anything else | a paragraph |

Bullets and checklist rows nest, two spaces per level, so a list can sit
inside a list:

```markdown
- [ ] pack
  - [x] passport
  - [ ] tickets
    - check the dates
```

Tab and Shift+Tab move a row in and out a level. Return continues the list at
the same depth, and Return on an empty row leaves the list.

Inline markdown — bold, italic, code, links — is never rewritten; it is styled
where it sits. An image with text on the same line stays a paragraph rather
than being split out, so nothing you wrote gets rearranged. Anything the
editor does not model, a table or a code fence say, is kept as paragraphs and
written back as it was found.

## Links between projects

Notes link to other projects with an ordinary relative markdown link:

```markdown
- [ ] Quote doors
  Blocked by [House move](house-move.md).
```

The link is relative to `projects/`, which makes it work in three places at
once: in the app, on github.com when browsing the file, and in Obsidian, which
follows relative markdown links as well as its own.

Obsidian's `[[Wikilink]]` form is **accepted on read** — pasted from a vault or
typed out of habit — and rewritten to the portable form when the app saves the
note. `[[slug|custom label]]` keeps the label. A wikilink naming a project that
does not exist is left exactly as written rather than turned into a dead link.

## Conflicts

Nothing in the format records which device wrote a file, so a project edited in
two places is reconciled by content: items are matched on their text and the
union is kept. That is the app's behaviour, not a property of the format — the
files themselves are ordinary markdown, and a merge done by hand or by git is
equally valid.

## Why this shape

It is plain markdown, so GitHub renders it, Claude and ChatGPT can read a whole
project by being handed one file, and you can edit it in any text editor without
the app. Nothing about the format depends on the app existing.
