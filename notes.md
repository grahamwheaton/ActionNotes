ActionNotes v0.9.3.

**Android** — `actionnotes-v0.9.3.apk`

Download it on your phone, open it, and allow installation from
unknown sources when prompted.

**Debug-signed.** No release keystore is configured, and CI generates a fresh debug key each run, so this APK will not install over another build — uninstall the old one first. See the README to set up signing.

**Windows** — `actionnotes-v0.9.3-windows.zip`

Unzip anywhere and run `actionnotes.exe`. There is no installer:
it runs in place and needs no admin rights, but keep the unzipped
files together — the executable needs the DLLs and `data` folder
beside it. Windows may warn about an unrecognised app, as the build
is not code-signed.

**Windows, one file** — `actionnotes-v0.9.3-portable.exe`

The same build wrapped in one executable, for carrying about. A
Flutter app cannot be a single binary — the engine loads its DLLs
and `data` from disk — so this unpacks the folder to
`%LOCALAPPDATA%\ActionNotes\v0.9.3` the first time you run it and
starts it from there; after that it opens straight away. It is
per-user and never asks for admin. Some antivirus dislikes a
program that unpacks and launches another; the zip above is the one
to use if yours objects.
