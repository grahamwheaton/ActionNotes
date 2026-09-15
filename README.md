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

First pass: project list, checklist editing, markdown read/write, GitHub sync,
settings. Android is the platform being built and tested; Windows builds from
the same source but has not been run yet.

## Setup

1. Create a GitHub repo to hold your notes. It can be private — an empty repo is
   fine, the app creates `projects/` on first save.
2. Create a fine-grained personal access token at
   <https://github.com/settings/tokens?type=beta>, scoped to that one repo, with
   **Contents: Read and write**.
3. Install the app, open **Settings**, and enter owner, repo, branch and token.
4. Hit sync. Projects you create appear in the repo as markdown files.

The token is held in the platform keystore (Android Keystore / Windows DPAPI)
via `flutter_secure_storage`, not in plain preferences.

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

CI builds a debug APK on every push to this branch; download it from the
workflow run's artifacts.

## Using it with Claude or ChatGPT

Point the model at the notes repo, or paste a project file. The format is
designed so a model can both read it and write a valid file back — the spec in
`docs/FILE_FORMAT.md` is short enough to include in a prompt.
