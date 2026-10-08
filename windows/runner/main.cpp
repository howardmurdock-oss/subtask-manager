#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

#include <string>

namespace {

// subtaskmanager:// links open this app, for this Windows user. Written on
// every start, so a moved or updated copy keeps the links pointing at it.
void RegisterLinkScheme() {
  wchar_t exe[MAX_PATH];
  if (!::GetModuleFileNameW(nullptr, exe, MAX_PATH)) return;
  const std::wstring command = L"\"" + std::wstring(exe) + L"\" \"%1\"";
  const wchar_t* name = L"URL:(sub)Task Manager";
  HKEY key;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\subtaskmanager", 0, nullptr, 0, KEY_WRITE, nullptr,
                        &key, nullptr) == ERROR_SUCCESS) {
    ::RegSetValueExW(key, nullptr, 0, REG_SZ, reinterpret_cast<const BYTE*>(name),
                     static_cast<DWORD>((wcslen(name) + 1) * sizeof(wchar_t)));
    ::RegSetValueExW(key, L"URL Protocol", 0, REG_SZ, reinterpret_cast<const BYTE*>(L""), sizeof(wchar_t));
    ::RegCloseKey(key);
  }
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\subtaskmanager\\shell\\open\\command", 0,
                        nullptr, 0, KEY_WRITE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
    ::RegSetValueExW(key, nullptr, 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()),
                     static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    ::RegCloseKey(key);
  }
}

// One copy at a time. A second start - from a link, say - hands its link to
// the running copy's window, brings that to the front, and goes.
bool HandOffToRunningCopy(const std::vector<std::string>& args) {
  ::CreateMutexW(nullptr, TRUE, L"Local\\SubTaskManagerSingleInstance");
  if (::GetLastError() != ERROR_ALREADY_EXISTS) return false;
  HWND running = ::FindWindowW(L"SUBTASKMANAGER_WINDOW", nullptr);
  if (!running) return false;
  for (const auto& arg : args) {
    if (arg.rfind("subtaskmanager:", 0) != 0) continue;
    COPYDATASTRUCT data;
    data.dwData = kOpenLinkMessage;
    data.cbData = static_cast<DWORD>(arg.size());
    data.lpData = const_cast<char*>(arg.data());
    ::SendMessageW(running, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data));
  }
  if (::IsIconic(running)) ::ShowWindow(running, SW_RESTORE);
  ::SetForegroundWindow(running);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  RegisterLinkScheme();
  if (HandOffToRunningCopy(command_line_arguments)) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"(sub)Task Manager", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
