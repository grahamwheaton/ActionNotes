#include <windows.h>
#include <shellapi.h>

#include <algorithm>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {
std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return value;
}

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void Marker(const fs::path& path, const std::string& text) {
  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  file << text;
  file.flush();
  Require(file.good(), "Could not write the update status.");
}

bool Reparse(const fs::path& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
}

void PlainTree(const fs::path& path) {
  Require(!Reparse(path), "An update folder is a link or junction.");
  if (fs::is_directory(path)) {
    for (const auto& entry : fs::recursive_directory_iterator(path)) {
      Require(!Reparse(entry.path()), "An update file is a link or junction.");
    }
  }
}

void Move(const fs::path& source, const fs::path& destination) {
  // Antivirus can briefly hold a file even after the app releases it.
  for (int attempt = 0; attempt < 50; ++attempt) {
    if (MoveFileExW(source.c_str(), destination.c_str(), MOVEFILE_WRITE_THROUGH)) {
      return;
    }
    Sleep(100);
  }
  throw std::runtime_error("Windows blocked replacing an app file. Close other "
                           "ActionNotes windows and check antivirus notifications.");
}

HANDLE Launch(const fs::path& install, const std::wstring& flag,
              const fs::path& marker) {
  const auto executable = install / L"actionnotes.exe";
  std::wstring command = L"\"" + executable.wstring() + L"\" " + flag +
                         L" \"" + marker.wstring() + L"\"";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr,
                      FALSE, 0, nullptr, install.c_str(), &startup, &process)) {
    return nullptr;
  }
  CloseHandle(process.hThread);
  return process.hProcess;
}

struct Change {
  fs::path name;
  bool backed_up = false;
  bool installed = false;
};

int Run(const fs::path& requested_install, const fs::path& requested_stage,
        DWORD parent_id) {
  // Canonical paths and direct-child checks constrain every rename/removal to
  // the known app directory and the freshly created staging directory.
  const fs::path install = fs::canonical(requested_install);
  const fs::path stage = fs::canonical(requested_stage);
  Require(Lower(stage.parent_path().wstring()) == Lower(install.wstring()) &&
              stage.filename().wstring().rfind(L".actionnotes-update-", 0) == 0,
          "The update staging folder is outside the app folder.");
  Require(!Reparse(requested_install) && !Reparse(requested_stage),
          "The app or update folder is a link or junction.");
  const fs::path payload = stage / L"payload";
  const fs::path backup = stage / L"backup";
  const fs::path error = stage / L"error.txt";
  std::vector<Change> changes;
  HANDLE parent = nullptr;
  HANDLE child = nullptr;
  HANDLE mutex = nullptr;
  bool parent_closed = false;
  bool changed = false;
  try {
    // Stable FNV hash keeps the mutex name short even for long install paths.
    unsigned long long hash = 14695981039346656037ULL;
    for (wchar_t c : Lower(install.wstring())) {
      hash = (hash ^ static_cast<unsigned long long>(c)) * 1099511628211ULL;
    }
    const auto mutex_name = L"Local\\ActionNotesUpdate-" + std::to_wstring(hash);
    mutex = CreateMutexW(nullptr, TRUE, mutex_name.c_str());
    Require(mutex != nullptr && GetLastError() != ERROR_ALREADY_EXISTS,
            "Another ActionNotes update is already running.");
    PlainTree(payload);
    Require(!fs::exists(backup), "This staging folder has already been used.");
    for (const auto& required : {L"actionnotes.exe", L"actionnotes_updater.exe",
                                 L"flutter_windows.dll", L"data\\app.so",
                                 L"data\\icudtl.dat",
                                 L"data\\flutter_assets\\AssetManifest.bin"}) {
      Require(fs::is_regular_file(payload / required) &&
                  fs::file_size(payload / required) > 0,
              "The Windows update is incomplete.");
    }
    for (const auto& entry : fs::directory_iterator(payload)) {
      const auto name = entry.path().filename();
      Require((name == L"data" && entry.is_directory()) ||
                  (entry.is_regular_file() &&
                   (name == L"actionnotes.exe" || name == L"actionnotes_updater.exe" ||
                    name.extension() == L".dll")),
              "Unexpected file in the Windows update.");
      if (fs::exists(install / name)) PlainTree(install / name);
      changes.push_back({name});
    }
    // Deterministic ordering is also useful when diagnosing a failed move.
    std::sort(changes.begin(), changes.end(),
              [](const Change& a, const Change& b) { return a.name < b.name; });
    parent = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                         FALSE, parent_id);
    Require(parent != nullptr, "The running app could not be found.");
    wchar_t image[32768];
    DWORD length = 32768;
    Require(QueryFullProcessImageNameW(parent, 0, image, &length) != FALSE &&
                Lower(fs::canonical(fs::path(image)).wstring()) ==
                    Lower((install / L"actionnotes.exe").wstring()),
            "The updater was not started by this ActionNotes installation.");
    fs::create_directory(backup);
    Marker(stage / L"ready", "ready");
    Require(WaitForSingleObject(parent, 120000) == WAIT_OBJECT_0,
            "ActionNotes did not close. The update was cancelled.");
    CloseHandle(parent);
    parent = nullptr;
    parent_closed = true;

    for (auto& change : changes) {
      if (fs::exists(install / change.name)) {
        Move(install / change.name, backup / change.name);
        change.backed_up = true;
        changed = true;
      }
      Move(payload / change.name, install / change.name);
      change.installed = true;
      changed = true;
    }
    child = Launch(install, L"--update-ready", stage / L"started");
    Require(child != nullptr, "Windows could not start the updated app.");
    // The Flutter app acknowledges its first rendered frame, rather than
    // treating successful process creation as a successful update.
    bool started = false;
    for (int attempt = 0; attempt < 600; ++attempt) {
      if (WaitForSingleObject(child, 0) == WAIT_OBJECT_0) break;
      if (fs::exists(stage / L"started")) { started = true; break; }
      Sleep(100);
    }
    Require(started, "The updated app did not finish starting.");
    CloseHandle(child);
    child = nullptr;
    Marker(stage / L"complete", "The updated app started successfully.");
    // Keep the backup until the next update: it also gives manual recovery
    // a known location if the machine shuts down during a replacement.
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    return 0;
  } catch (const std::exception& problem) {
    if (child != nullptr) {
      TerminateProcess(child, 1);
      WaitForSingleObject(child, 10000);
      CloseHandle(child);
    }
    bool restored = true;
    if (changed) {
      for (auto it = changes.rbegin(); it != changes.rend(); ++it) {
        try {
          if (it->installed) Move(install / it->name, payload / it->name);
          if (it->backed_up) Move(backup / it->name, install / it->name);
        } catch (...) { restored = false; }
      }
    }
    std::string message = problem.what();
    message += restored ? " Your previous version has been kept."
                        : " Recovery needs attention. Your previous files are in "
                          "the backup folder beside this error report.";
    try { Marker(error, message); } catch (...) {}
    if (parent != nullptr) CloseHandle(parent);
    if (mutex != nullptr) { ReleaseMutex(mutex); CloseHandle(mutex); }
    if (parent_closed && restored) {
      HANDLE previous = Launch(install, L"--update-error", error);
      if (previous != nullptr) { CloseHandle(previous); return 1; }
    }
    if (parent_closed) {
      const std::wstring text = L"ActionNotes could not complete the update. "
          L"Your notes have not been moved. Recovery details are in:\n\n" +
          error.wstring();
      MessageBoxW(nullptr, text.c_str(), L"ActionNotes update", MB_OK | MB_ICONERROR);
    }
    return 1;
  }
}
}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  int count = 0;
  LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  if (arguments == nullptr || count != 4) {
    if (arguments != nullptr) LocalFree(arguments);
    return 2;
  }
  int result = 2;
  try {
    const auto parent = std::stoul(arguments[3]);
    result = Run(fs::path(arguments[1]), fs::path(arguments[2]), parent);
  } catch (...) { /* An invalid invocation must not change any files. */ }
  LocalFree(arguments);
  return result;
}
