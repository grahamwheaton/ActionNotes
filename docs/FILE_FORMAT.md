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

- `- [ ]` is open, `- [x]` is done.
- A **⭐ before the text** marks the item starred — the app's equivalent of
  Microsoft To Do's star. It is stripped from the displayed text.
- **Lines indented by two spaces** after an item are that item's notes. The
  indent is what distinguishes a note from the next item, so an indented `-`
  is a bullet inside a note rather than a new item.
- A blank line inside a note block is kept, so notes can have paragraphs.
- The first unindented line after a note block ends it.

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

## Why this shape

It is plain markdown, so GitHub renders it, Claude and ChatGPT can read a whole
project by being handed one file, and you can edit it in any text editor without
the app. Nothing about the format depends on the app existing.
