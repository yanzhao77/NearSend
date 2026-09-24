#include "platform_qr_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <cstdint>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr char kChannelName[] = "com.nearsend.app/qr";
constexpr uintmax_t kMaxImageBytes = 16 * 1024 * 1024;

std::unique_ptr<EncodableValue> PickImage(HWND parent_window) {
  ComPtr<IFileDialog> dialog;
  if (FAILED(::CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
    throw std::runtime_error("image picker unavailable");
  }
  const COMDLG_FILTERSPEC filters[] = {
      {L"Image files", L"*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.webp"},
      {L"All files", L"*.*"},
  };
  DWORD options = 0;
  if (FAILED(dialog->GetOptions(&options)) ||
      FAILED(dialog->SetOptions(options | FOS_FILEMUSTEXIST |
                                FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST)) ||
      FAILED(dialog->SetFileTypes(2, filters))) {
    throw std::runtime_error("image picker setup failed");
  }
  const HRESULT shown = dialog->Show(parent_window);
  if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return nullptr;
  if (FAILED(shown)) throw std::runtime_error("image picker failed");

  ComPtr<IShellItem> item;
  if (FAILED(dialog->GetResult(&item))) {
    throw std::runtime_error("image selection failed");
  }
  PWSTR selected = nullptr;
  if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &selected)) ||
      selected == nullptr) {
    throw std::runtime_error("selected image is unavailable");
  }
  const std::wstring path(selected);
  ::CoTaskMemFree(selected);

  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) throw std::runtime_error("selected image cannot be opened");
  const std::streamoff size = input.tellg();
  if (size <= 0 || static_cast<uintmax_t>(size) > kMaxImageBytes) {
    throw std::runtime_error("selected image has an invalid size");
  }
  std::vector<uint8_t> bytes(static_cast<size_t>(size));
  input.seekg(0);
  if (!input.read(reinterpret_cast<char*>(bytes.data()),
                  static_cast<std::streamsize>(size))) {
    throw std::runtime_error("selected image cannot be read");
  }
  return std::make_unique<EncodableValue>(bytes);
}

}  // namespace

void RegisterPlatformQrChannel(flutter::FlutterEngine* engine,
                               HWND parent_window) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [parent_window](const flutter::MethodCall<EncodableValue>& call,
                      std::unique_ptr<flutter::MethodResult<EncodableValue>>
                          result) {
        if (call.method_name() != "pickImage") {
          result->NotImplemented();
          return;
        }
        try {
          auto image = PickImage(parent_window);
          image == nullptr ? result->Success() : result->Success(*image);
        } catch (const std::exception&) {
          result->Error("NS-QR-IMAGE", "QR image import failed");
        }
      });
}
