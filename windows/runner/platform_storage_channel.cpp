#include "platform_storage_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <wrl/client.h>

#include <memory>
#include <string>

#include "utils.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr char kChannelName[] = "com.nearsend.app/files";

bool CanWriteDirectory(const std::wstring& path) {
  if (path.empty()) {
    return false;
  }
  HANDLE handle = ::CreateFileW(
      path.c_str(), FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    return false;
  }
  ::CloseHandle(handle);
  return true;
}

EncodableMap Location(const std::string& path, const std::string& label,
                      const std::string& permission_state) {
  return EncodableMap{
      {EncodableValue("kind"), EncodableValue("nativeDirectory")},
      {EncodableValue("opaqueValue"), EncodableValue(path)},
      {EncodableValue("displayName"), EncodableValue(label)},
      {EncodableValue("permissionState"), EncodableValue(permission_state)},
  };
}

std::string DisplayName(const std::wstring& path) {
  std::wstring normalized = path;
  while (normalized.size() > 3 &&
         (normalized.back() == L'\\' || normalized.back() == L'/')) {
    normalized.pop_back();
  }
  const size_t separator = normalized.find_last_of(L"\\/");
  const std::wstring name = separator == std::wstring::npos
                                ? normalized
                                : normalized.substr(separator + 1);
  const std::string encoded = Utf8FromUtf16(name.c_str());
  return encoded.empty() ? "Selected folder" : encoded;
}

std::string Argument(const flutter::MethodCall<EncodableValue>& call,
                     const char* name) {
  const auto* arguments = std::get_if<EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    return std::string();
  }
  const auto found = arguments->find(EncodableValue(name));
  if (found == arguments->end()) {
    return std::string();
  }
  const auto* value = std::get_if<std::string>(&found->second);
  return value == nullptr ? std::string() : *value;
}

std::unique_ptr<EncodableValue> DefaultReceiveLocation() {
  PWSTR known_path = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_Downloads, KF_FLAG_DEFAULT,
                                    nullptr, &known_path)) ||
      known_path == nullptr) {
    return nullptr;
  }
  const std::wstring path(known_path);
  ::CoTaskMemFree(known_path);
  return std::make_unique<EncodableValue>(Location(
      Utf8FromUtf16(path.c_str()), DisplayName(path),
      CanWriteDirectory(path) ? "granted" : "denied"));
}

std::unique_ptr<EncodableValue> PickReceiveDirectory(HWND parent_window) {
  ComPtr<IFileDialog> dialog;
  if (FAILED(::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
    return nullptr;
  }
  DWORD options = 0;
  if (FAILED(dialog->GetOptions(&options)) ||
      FAILED(dialog->SetOptions(options | FOS_PICKFOLDERS |
                                FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST))) {
    return nullptr;
  }
  const HRESULT shown = dialog->Show(parent_window);
  if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    return nullptr;
  }
  if (FAILED(shown)) {
    return nullptr;
  }
  ComPtr<IShellItem> item;
  if (FAILED(dialog->GetResult(&item))) {
    return nullptr;
  }
  PWSTR selected = nullptr;
  if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &selected)) ||
      selected == nullptr) {
    return nullptr;
  }
  const std::wstring path(selected);
  ::CoTaskMemFree(selected);
  return std::make_unique<EncodableValue>(Location(
      Utf8FromUtf16(path.c_str()), DisplayName(path),
      CanWriteDirectory(path) ? "granted" : "denied"));
}

EncodableValue ValidateLocation(const std::string& path_utf8) {
  const std::wstring path = Utf16FromUtf8(path_utf8);
  const DWORD attributes = path.empty() ? INVALID_FILE_ATTRIBUTES
                                        : ::GetFileAttributesW(path.c_str());
  const bool exists = attributes != INVALID_FILE_ATTRIBUTES &&
                      (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  const std::string permission_state =
      !exists ? "unavailable" : (CanWriteDirectory(path) ? "granted" : "denied");
  return EncodableValue(Location(path_utf8, DisplayName(path),
                                 permission_state));
}

EncodableValue MeasureFreeSpace(const std::string& path_utf8) {
  const std::wstring path = Utf16FromUtf8(path_utf8);
  ULARGE_INTEGER available{};
  wchar_t volume_path[MAX_PATH] = {};
  const bool measured = !path.empty() &&
                        ::GetDiskFreeSpaceExW(path.c_str(), &available, nullptr,
                                              nullptr) != FALSE;
  const bool has_volume = measured &&
                          ::GetVolumePathNameW(path.c_str(), volume_path,
                                               MAX_PATH) != FALSE;
  EncodableMap result{
      {EncodableValue("volume"),
       EncodableValue(has_volume ? Utf8FromUtf16(volume_path) : "unknown")},
      {EncodableValue("label"), EncodableValue("Windows storage")},
      {EncodableValue("freeBytes"),
       measured ? EncodableValue(static_cast<int64_t>(available.QuadPart))
                : EncodableValue()},
  };
  return EncodableValue(result);
}

}  // namespace

void RegisterPlatformStorageChannel(flutter::FlutterEngine* engine,
                                    HWND parent_window) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [parent_window](
          const flutter::MethodCall<EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == "defaultReceiveLocation") {
          auto location = DefaultReceiveLocation();
          if (location == nullptr) {
            result->Success();
          } else {
            result->Success(*location);
          }
          return;
        }
        if (call.method_name() == "pickReceiveDirectory") {
          auto location = PickReceiveDirectory(parent_window);
          if (location == nullptr) {
            result->Success();
          } else {
            result->Success(*location);
          }
          return;
        }
        if (call.method_name() == "validateReceiveDirectory") {
          const std::string path = Argument(call, "locationRef");
          if (path.empty()) {
            result->Error("NS-STORAGE", "a locationRef argument is required");
          } else {
            result->Success(ValidateLocation(path));
          }
          return;
        }
        if (call.method_name() == "measureFreeSpace") {
          result->Success(MeasureFreeSpace(Argument(call, "locationRef")));
          return;
        }
        result->NotImplemented();
      });
}
