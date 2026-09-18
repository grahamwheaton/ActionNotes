; A single-file portable ActionNotes.
;
; A Flutter app cannot be one binary — actionnotes.exe is a launcher and the
; engine loads flutter_windows.dll, the plugin DLLs and data/ from disk — so
; this wraps the whole folder in an executable that unpacks it once and runs
; it. NSIS rather than a 7-Zip SFX module because NSIS is on the build image
; and needs nothing downloaded, and because it can unpack to a known place:
; the first run costs a few seconds, every run after it starts straight away.

Unicode true
Name "ActionNotes"
; Absolute, passed in: a relative OutFile lands beside this script rather than
; where the build is run from, which is where the first attempt went looking.
!ifndef OUT
  !define OUT "actionnotes-portable.exe"
!endif
OutFile "${OUT}"
; Per-user, so it never asks for admin.
RequestExecutionLevel user
SilentInstall silent
SetCompressor /SOLID lzma

!ifndef VERSION
  !define VERSION "dev"
!endif

Section
  StrCpy $INSTDIR "$LOCALAPPDATA\ActionNotes\${VERSION}"

  ; Already unpacked by an earlier run of this same file: just start it.
  IfFileExists "$INSTDIR\actionnotes.exe" ready

  SetOutPath "$INSTDIR"
  File /r "${SOURCE}\*.*"

ready:
  SetOutPath "$INSTDIR"
  Exec '"$INSTDIR\actionnotes.exe"'
SectionEnd
