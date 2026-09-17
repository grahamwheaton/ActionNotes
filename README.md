# ActionNotes

A checklist app whose storage format is plain markdown in a GitHub repo.

The point: your notes stay readable without the app. GitHub renders them, any
text editor edits them, and you can hand a whole project to Claude or ChatGPT by
pasting one file — or by pointing the model at the repo.

## What it is

- A Flutter app for **Android** and **Windows** (one codebase).
- Projects are markdown files under `projects/` — see
  [docs/FILE_FORMAT.md](docs/FILE_FORMAT.md).
- Storage is a GitHub repo you choose. The app talks to the GitHub REST API
  directly with a personal access token, so there is no server to run and no git
  install needed on the device.
- Edits are written to a local cache first and pushed to GitHub after, so
  going offline loses nothing — pending files are retried on the next sync.

## Current state

- Project sidebar on wide windows, pushed screens on a phone — one layout,
  two shapes.
- Checklists group open items first, with completed ones collapsed under a
  header at the bottom. New items are added at the top — Enter adds one,
  Ctrl+Enter adds it starred.
- Star any item, the way Microsoft To Do does. Starred items pin above the
  rest of the open ones and their rows are tinted, while the file keeps its
  own order.
- Tag an item by writing `[tag]` in its text, or anywhere in its notes. The
  brackets are shown as pills after the title, and tapping one finds
  everything carrying that tag. The tags live in the markdown itself, so
  anything reading the file sees them.
- Search across every project's titles, items and notes, saying where each
  hit came from. `[tag]` in the search box asks for that tag exactly.
- **Light or dark**, or whatever the system is doing — an override in
  Settings, remembered between runs.
- Per-item notes in markdown, with images pasted, dropped or picked from disk
  and stored in the repo, from either editor — the note on its own screen and
  the one that opens in the row share the same handling, so pasting a
  screenshot does not depend on which is open, and on a phone the block
  menu's own Paste takes an image too. Every item opens its notes
  underneath itself in the list — as the editor itself, so a checkbox in a note
  ticks and the text can be changed without going anywhere. Edits settle for a
  moment and then save, and closing the note writes it at once.
- Anywhere on an item opens its notes: the checkbox, star, notes marker and
  drag handle keep their own taps. **Alt-clicking** a notes marker opens or
  closes every item's notes in the project at once, following the row you
  clicked. On a wide window the note opens in the
  detail pane, so the project sidebar stays where it is and another project
  is one click away; on a phone it is a screen of its own, there being no
  sidebar to keep. A note in the pane writes as it goes and again when the
  pane is taken away, because choosing another project or deleting the item
  does not route through Save or back.
- Links between projects: type `[[` for a picker, or write a normal markdown
  link. Tap one in the preview to jump there.
- Right-click (or long-press) an item or a project for star, notes, rename and
  delete.
- Drag open items to reorder them, by the handle on the right.
- When a project changes both on a device and on GitHub, the app says so and
  offers a choice: keep yours, take GitHub's, or merge both.

## Notes, the Obsidian-ish parts

An item's notes are a markdown document. In the editor:

- **Type `[[`** to pick a project to link — the link is saved as
  `[Title](slug.md)`, which works in the app, on github.com and in Obsidian.
- **Paste an image** with Ctrl+V and it uploads to `attachments/` and appears
  inline. Pasting text still pastes text.
- **Drop an image file** onto the editor on the desktop to do the same.
- **One view, no preview pane.** A note is a stack of blocks drawn the way
  they read: headings at heading size, bullets with their marker, images as
  the picture. Typing `# ` turns a line into a heading and takes the hashes
  away; `- ` makes a bullet. Enter starts a new block, backspace at the start
  of a heading turns it back into a paragraph.
- **Lists nest.** `- ` makes a bullet, `- [ ] ` a checklist row with a real
  checkbox, and Tab moves a row in a level so a list can sit inside a list.
  Return continues the list; Return on an empty row leaves it.
- **Selecting across lines.** Drag with a mouse from one line into another,
  or hold shift and press up or down — which reaches into the next row once
  the caret has run out of text in this one — or shift-click a ¶ handle to
  reach from where you were to there. Ctrl+A takes the whole note. The
  selected rows highlight, and Escape, a click or typing gives the selection
  up.
  - Ctrl+C and Ctrl+X copy and cut the run **as markdown**, so what lands on
    the clipboard keeps its headings and bullets; backspace or delete takes
    the lines, in one undo step, and a note always keeps somewhere to type.
    The right-click menu has the same three, since the field's own Copy would
    answer with one line.
  - A block type — from the menu, or Ctrl+T for checkboxes, Ctrl+L for
    bullets — lands on every selected row, which is how a handful of typed
    lines becomes a checklist.
  - Because each block is its own text field, a selection that spans lines is
    a run of whole lines rather than a character range: the line the drag
    started in shows its own partial highlight, but copying takes the lines
    entire, and an inline mark like bold still applies to one block at a
    time. A touch drag is left to scroll the note, so a phone reaches across
    lines with shift and the arrow keys, or from a line's handle.
- **Inline markdown styles as you type** — `**bold**` looks bold, `*italic*`
  italic, `` `code` `` monospaced, a link shows its label rather than its
  target. The markers collapse to nothing until the caret enters the span they
  belong to, then appear dimmed so they can be edited. The text painter lays
  out the same spans the caret is measured against, so a hidden marker and the
  caret still agree about where everything sits; the only cost is that arrowing
  across one takes a keypress that moves nothing visible.
- **Undo and redo**, with Ctrl+Z and Ctrl+Shift+Z or the toolbar. History is
  kept over the whole note, so it covers the edits a text box cannot undo on
  its own: splitting a block, merging two with backspace, changing a row's
  kind, removing an image. Typing settles into one step per pause rather than
  one per keystroke.
- **Leaving saves.** Back — the arrow or Android's system back — writes the
  note, as does Save. Only an unchanged note writes nothing.

- **A ¶ handle beside every block** opens a block-type menu, in the shape
  MarkText uses: the kinds grouped, each with the markdown it writes and its
  shortcut. The handle shows what the block currently is — `¶`, `H2` — and
  fades in when the pointer is over that row or the caret is in it, so a note
  being read is just the note. It keeps its space while hidden, so revealing
  it never shuffles the text sideways.
- **Selecting text brings up a formatting toolbar** at the selection with
  bold, italic, strikethrough, code, link and clear, alongside the usual copy
  and paste.
- **Keyboard**: Ctrl+0 paragraph, Ctrl+1 to Ctrl+6 headers, Ctrl+L bullet,
  Ctrl+- horizontal line, Ctrl+B bold, Ctrl+I italic. Over a run of lines:
  Ctrl+A all, Ctrl+C copy, Ctrl+X cut, backspace or delete to remove.

What this is not: the markers reappear whenever the caret is among them, so it
is not quite Word. Backlinks, tags and the graph view are not here either.

## When the same project changes in two places

Edit a project on your phone while it also changes on GitHub — from the other
device, the web editor, or a model — and the push is refused, because
overwriting blindly would lose whichever change it did not know about.

The app shows a bar naming the project with a **Resolve** button. It puts both
versions side by side, with a preview of the merge, and offers three outcomes:

| Choice | What happens |
| --- | --- |
| **Keep mine** | Your version is written over GitHub's. Theirs stays in the commit history. |
| **Use GitHub's** | Your local edits are discarded and GitHub's version is taken. |
| **Merge both** | Every item from either side is kept. |

Merging matches items by their text, ignoring case. An item present on both
sides is ticked if it was ticked anywhere, starred if it was starred anywhere,
and if its notes differ both are kept with a `<!-- from GitHub -->` marker
between them so you can tidy up. Because an item is identified only by its
text, **an item you deleted on one device reappears if it is still on the
other** — deletion is indistinguishable from never having existed without a
history, and an item coming back is easier to notice and undo than one quietly
disappearing. Choose *Keep mine* when you meant the deletions.

Whichever you pick, the project ends up agreeing with GitHub and syncs
normally again.

Android and Windows both build in CI. Neither binary has been run by a human
yet, so treat the first launch on each platform as untested.

## Working with the notes repo

Claude keeps the action list in the notes repo current while working on the
app: it may add items and tick them off, but never delete one. Removing an
item is the owner's call, so an item Claude thinks is unnecessary stays on the
list with its reasoning noted instead of quietly disappearing. The notes
repo's own README records the same agreement, where anyone reading those files
will see it.

## Setup

1. Create a GitHub repo to hold your notes. It can be private — an empty repo is
   fine, the app creates `projects/` on first save.
2. Install the ActionNotes GitHub App on that repo, from the app's page on
   github.com. This is what grants access, and it reaches only the repos you
   tick.
3. Open **Settings**, hit **Sign in**, and approve the code it shows you in the
   browser. Signing in fills the owner in for you, and the button beside
   **Repository** lists and searches the repos the app is installed on —
   picking one sets the owner, name and default branch together. All three
   fields can still be typed, for notes kept under an org or a repo the list
   cannot see.
4. Hit sync. Projects you create appear in the repo as markdown files.

Signing in uses GitHub's device flow: the app shows a short code, you approve it
on github.com, and a token comes back. The wait is patient about the network —
a connection dropped between polls is retried rather than ending a sign-in
that has already been approved. No password is ever typed into the app,
and the client ID it ships with is public by design — the device flow is built
for apps that cannot keep a secret, so there is none to leak.

If you would rather mint your own token, **Use a personal access token instead**
in Settings still takes a fine-grained token scoped to the one repo with
**Contents: Read and write**.

Either way the token is held in the platform keystore (Android Keystore /
Windows DPAPI) via `flutter_secure_storage`, not in plain preferences.

## Building

Android APK:

```sh
flutter pub get
flutter build apk --release
```

Windows:

```sh
flutter build windows --release
```

CI builds a debug APK and a Windows release on every push; download them from
the workflow run's artifacts.

### Releases

Pushing a version tag publishes an Android APK and a Windows build as release
assets:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The APK is a plain `.apk`, so it installs straight from the phone browser —
unlike a CI artifact, which arrives zipped.

The Windows asset is a zip of the built app. There is no installer: unzip it
anywhere and run `actionnotes.exe`. It needs no admin rights, but the
executable has to keep its DLLs and `data` folder beside it, so run it from the
unzipped folder rather than moving the exe out on its own. Windows may warn
about an unrecognised app, as the build is not code-signed.

### Release signing

Without a keystore the release build falls back to debug keys, and CI generates
a fresh debug key on every run, so those APKs will not install over one another
— Android treats each as a different app and makes you uninstall first.

To sign properly, generate an upload key once:

```sh
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA \
  -keysize 2048 -validity 10000 -alias upload
base64 -w0 upload-keystore.jks
```

Then add four repository secrets under Settings → Secrets and variables →
Actions:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | the base64 output above |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | the key password |

The next tag picks them up automatically. Keep `upload-keystore.jks` somewhere
safe and out of the repo — losing it means future builds can no longer upgrade
an installed app. `.gitignore` already excludes keystores and
`android/key.properties`.

## Using it with Claude or ChatGPT

Point the model at the notes repo, or paste a project file. The format is
designed so a model can both read it and write a valid file back — the spec in
`docs/FILE_FORMAT.md` is short enough to include in a prompt.
