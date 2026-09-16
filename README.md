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

CI builds a debug APK and a Windows release on every push; download them from
the workflow run's artifacts.

### Releases

Pushing a version tag publishes a release APK as a downloadable asset:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The asset is a plain `.apk`, so it installs straight from the phone browser —
unlike a CI artifact, which arrives zipped.

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
