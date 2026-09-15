# ActionNotes markdown format

Every project is one markdown file in the repo under `projects/`.

```
projects/
  groceries.md
  house-move.md
```

The filename is a slug of the project title. It never changes after creation,
even if the title is edited — the title lives in the front matter.

## File anatomy

```markdown
---
title: House move
created: 2026-09-15T09:12:44Z
updated: 2026-09-15T18:30:02Z
---

# House move

- [ ] Book the van
- [x] Cancel broadband
- [ ] Redirect post

Landlord's number is in the drawer.
```

Three parts, in this order:

1. **Front matter** — a `---` fenced block of `key: value` lines. Keys:
   - `title` (required) — display name of the project.
   - `created` / `updated` — UTC ISO-8601 timestamps, maintained by the app.
   - Unknown keys are preserved verbatim on write, so you can add your own.
2. **Heading** — a single `# Title` line mirroring the front-matter title, so the
   file reads well on GitHub and when pasted into a chat. Optional on read.
3. **Body** — checklist items, then any free text.
   - `- [ ] text` is an open item, `- [x] text` is a done item.
   - Any other non-blank line after the items is kept as the project's notes.

## Rules the parser follows

- Reading is forgiving: missing front matter, a missing heading, `*` instead of
  `-`, or `[X]` instead of `[x]` all parse fine.
- Writing is canonical: the app always emits the shape shown above, so diffs
  stay small and reviewable.
- Item order in the file is the item order in the app.
- Anything the app does not understand in the front matter is round-tripped
  unchanged rather than dropped.

## Why this shape

It is plain markdown, so GitHub renders it, Claude and ChatGPT can read a whole
project by being handed one file, and you can edit it in any text editor without
the app. Nothing about the format depends on the app existing.
