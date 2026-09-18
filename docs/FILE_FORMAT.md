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
   - `mode` — `notes` opens the project as a document instead of a checklist.
     Absent means a checklist, and the app writes it only when it is `notes`,
     so a checklist's file is untouched by this existing. An unrecognised
     value reads as a checklist.
   - Unknown keys are preserved verbatim on write, so you can add your own.
2. **Heading** — a single `# Title` line mirroring the front-matter title, so the
   file reads well on GitHub and when pasted into a chat. Optional on read.
3. **Items** — the checklist. See below.
4. **Project notes** — any unindented free text after the items.
5. **Sections** — optional `##` headings, each with its own items and prose.
   See below.

## Sections: `##`

A `##` heading starts a section. Everything after it, until the next heading,
belongs to it:

```markdown
# House move

- [ ] Redirect post

## Packing

- [ ] Boxes from the shop
- [ ] Label the kitchen ones

## Notes from the survey

Damp in the back bedroom, and the boiler is 2011.
```

There is nothing to declare. A section holding checklist lines is a list; one
holding prose is a note; one holding both shows its items and then its prose.
The kind is read from what is in it, which is why headings were used for this
rather than new syntax — a section typed on GitHub becomes one in the app
without anyone saying which sort it is.

What the parser does with them:

- Items above the first `##` stay where they have always been. A file with no
  headings is exactly the file it was before sections existed.
- Two or more hashes start a section; the project's own `# Title` does not. A
  `###` is a section too rather than a nested one — one level is what the app
  offers, and a deeper heading typed by hand should still land somewhere.
- An **indented** `##` belongs to the note above it, the same as an indented
  `- [ ]` does. That is what keeps a heading written inside an item's notes
  inside them.
- A repeated heading joins the first one rather than becoming a second section
  of the same name, since an item names its section and two of one name could
  not be told apart.
- A heading with nothing under it is kept, so a section made before anything is
  written into it survives.

Sections are one level deep on purpose. Arbitrary nesting would make search,
starring, moving, archiving and the merge each need a story for a tree instead
of a list; a section that wants to contain a section usually wanted to be its
own project, and `[[` links one.

## Items

```markdown
- [ ] An open item
- [x] A completed item
- [ ] ⭐ A starred item
- [ ] An item with tags [bug] [next week]
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
  Microsoft To Do's star. It is stripped from the displayed text. The app also
  tints a starred item's row while it is open.
- **`[tag]` anywhere in an item's text is a tag.** The app shows the item
  without the brackets and the tags as pills after it, and tapping one
  searches for everything carrying it. Tags live in the line itself rather
  than in front matter, so anything reading the file sees them, and a tag is
  removed by deleting it from the line.
  - A tag may hold spaces (`[next week]`), and case is kept but ignored when
    matching, so `[Bug]` and `[bug]` are one tag.
  - **A tag written in an item's notes counts as that item's tag too**, and
    shows as a pill after its title. Only the ones on the item's own line are
    taken out of the displayed title; a tag in a note is shown where it can be
    seen without opening the note, and edited where it was written. A
    checklist row's own `- [ ]` or `- [x]` marker inside a note is not a tag.
  - Deliberately **not** tags, because `[...]` is also link syntax: a link or
    image label (`[the docs](https://example.com)`) and a wikilink
    (`[[Shopping]]`), which a note gives its own meaning to.
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

## Asking someone: `@name`

`@name` anywhere in an item or its notes asks that person — usually a model —
to pick it up.

```markdown
- [ ] Work out why the sync conflicts @Claude
  **graham** · 2026-09-18T09:30Z
  Happens when I type while it is pushing.
```

- The app shows an **@Claude** pill on any item waiting on a name, and
  `@claude` in the search box lists them. The search screen's "Waiting on"
  row says who is owed what, across every project.
- **A mention is answered by a reply, not by being deleted.** A name is
  waiting only while the last message in the note is from someone else, so
  asking again later makes the item wait again, and nothing has to be edited
  away to mark it done. That matters when the other party is a model that has
  been told not to delete anything.
- The mention stays in the sentence, unlike a `[tag]`: "@Claude pick this up"
  says nothing with the name taken out.
- An email address is not a mention — the `@` there follows a word character.
- **A mention inside a code span or fenced block is not an ask**, so writing
  `` `@Claude` `` while explaining the convention does not quietly request
  anything. (These notes managed exactly that the first time they described
  it.)

## Notes as a conversation

A note can hold an exchange rather than just prose. The convention is a
**signed paragraph**: a line holding nothing but a bold name — optionally
followed by `·` and when it was said — starts a message, and everything until
the next such line is what was said.

```markdown
- [ ] Fix the sync
  **Claude** · 2026-09-18T09:12Z
  Found it: a push threw away the SHA it was given. Fixed, with five tests.

  **grahamwheaton** · 2026-09-18T09:30Z
  Thanks — does it need a release?
```

- The app shows such a note as a stream of bubbles, yours on one side and a
  model's on the other, with a box at the bottom to add one. The markdown is
  still the note: anything written there is as editable in the block editor,
  in a text editor, or on GitHub as ever.
- **Times are written in UTC**, to the minute, so the file cannot be misread
  in another timezone. The app shows them in local time.
- A line of bold text is a signature only if that is *all* the line holds, so
  `**important**` in the middle of a sentence is still just bold.
- Text before the first signature belongs to nobody: an older note that was
  never a conversation keeps its words, rather than being attributed to
  whoever writes next.
- A model writing into a repo should sign with its own name — `**Claude**` or
  `**ChatGPT**` — which is what lets the app put the two sides apart, and what
  the notes repo's own README asks for.

## Archive

Archiving a project's completed items appends them to
`archive/<project-slug>.md`, as the same `- [x]` lines with the same indented
notes, under an `## Asking someone: `@name`

`@name` anywhere in an item or its notes asks that person — usually a model —
to pick it up.

```markdown
- [ ] Work out why the sync conflicts @Claude
  **graham** · 2026-09-18T09:30Z
  Happens when I type while it is pushing.
```

- The app shows an **@Claude** pill on any item waiting on a name, and
  `@claude` in the search box lists them. The search screen's "Waiting on"
  row says who is owed what, across every project.
- **A mention is answered by a reply, not by being deleted.** A name is
  waiting only while the last message in the note is from someone else, so
  asking again later makes the item wait again, and nothing has to be edited
  away to mark it done. That matters when the other party is a model that has
  been told not to delete anything.
- The mention stays in the sentence, unlike a `[tag]`: "@Claude pick this up"
  says nothing with the name taken out.
- An email address is not a mention — the `@` there follows a word character.
- **A mention inside a code span or fenced block is not an ask**, so writing
  `` `@Claude` `` while explaining the convention does not quietly request
  anything. (These notes managed exactly that the first time they described
  it.)

## Notes as a conversation

A note can hold an exchange rather than just prose. The convention is a
**signed paragraph**: a line holding nothing but a bold name — optionally
followed by `·` and when it was said — starts a message, and everything until
the next such line is what was said.

```markdown
- [ ] Fix the sync
  **Claude** · 2026-09-18T09:12Z
  Found it: a push threw away the SHA it was given. Fixed, with five tests.

  **grahamwheaton** · 2026-09-18T09:30Z
  Thanks — does it need a release?
```

- The app shows such a note as a stream of bubbles, yours on one side and a
  model's on the other, with a box at the bottom to add one. The markdown is
  still the note: anything written there is as editable in the block editor,
  in a text editor, or on GitHub as ever.
- **Times are written in UTC**, to the minute, so the file cannot be misread
  in another timezone. The app shows them in local time.
- A line of bold text is a signature only if that is *all* the line holds, so
  `**important**` in the middle of a sentence is still just bold.
- Text before the first signature belongs to nobody: an older note that was
  never a conversation keeps its words, rather than being attributed to
  whoever writes next.
- A model writing into a repo should sign with its own name — `**Claude**` or
  `**ChatGPT**` — which is what lets the app put the two sides apart, and what
  the notes repo's own README asks for.

## Archived <date>` heading. The directory is deliberately
outside `projects/`, which is the only one the app scans, so an archived item
is kept and readable — on GitHub, in an editor, by a model — without coming
back as a checklist. Nothing is deleted.

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

An attachment nothing refers to is removed: after a note is saved, files in
that project's attachment directory with no reference left pointing at them
are deleted, and deleting a project takes its whole attachment directory with
it. Tidying is best effort — a file left behind is untidy rather than broken,
so a failure here is never reported as an error.

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
- An item remembers which `##` section it is under, so the project's items stay
  one flat list in one order. Everything addressed by position — search,
  reveal, move, reorder, the merge — goes on meaning what it meant before
  sections existed.
- A merge keeps the sections from both sides, local order first, and merges
  each section's prose the way it merges a project's. A heading is kept even
  when nothing is left under it: someone wrote it, and dropping it silently
  reorganises the list.

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
