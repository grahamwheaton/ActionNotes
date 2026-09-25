#include <windows.h>
#include <shellapi.h>
#include <filesystem>
#include <fstream>
#include <string>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  int count = 0;
  auto args = CommandLineToArgvW(GetCommandLineW(), &count);
  if (count == 2 && std::wstring(args[1]) == L"--hold") {
    Sleep(INFINITE);
    return 0;
  }
  wchar_t module[32768];
  GetModuleFileNameW(nullptr, module, 32768);
  auto root = std::filesystem::path(module).parent_path();
  std::ofstream(root / L"launched.pid") << GetCurrentProcessId();
  if (count == 3 && std::wstring(args[1]) == L"--update-ready") {
#ifdef FAIL_START
    return 17;
#else
    std::ofstream(std::filesystem::path(args[2])) << "started";
#endif
  }
  if (count == 3 && std::wstring(args[1]) == L"--update-error") {
    std::ofstream(root / L"recovered.txt") << "previous app restarted";
  }
  LocalFree(args);
  Sleep(INFINITE);
  return 0;
}
