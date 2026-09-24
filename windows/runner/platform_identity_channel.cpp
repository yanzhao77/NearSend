#include "platform_identity_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <windows.h>
#include <wincrypt.h>

#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "utils.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kChannelName[] = "com.nearsend.app/secure_identity";
constexpr size_t kMaxIdentityBytes = 1024 * 1024;
constexpr BYTE kEntropy[] = "NearSend installation identity v1";

std::filesystem::path IdentityPath() {
  PWSTR local_app_data = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                  nullptr, &local_app_data))) {
    return {};
  }
  std::filesystem::path path(local_app_data);
  CoTaskMemFree(local_app_data);
  return path / L"NearSend" / L"identity.v1.bin";
}

DATA_BLOB Entropy() {
  return DATA_BLOB{static_cast<DWORD>(sizeof(kEntropy) - 1),
                   const_cast<BYTE*>(kEntropy)};
}

std::optional<std::string> ReadIdentity() {
  const std::filesystem::path path = IdentityPath();
  if (path.empty() || !std::filesystem::exists(path)) {
    return std::nullopt;
  }
  const auto size = std::filesystem::file_size(path);
  if (size == 0 || size > kMaxIdentityBytes) {
    throw std::runtime_error("identity ciphertext has an invalid size");
  }
  std::vector<BYTE> encrypted(static_cast<size_t>(size));
  std::ifstream input(path, std::ios::binary);
  if (!input.read(reinterpret_cast<char*>(encrypted.data()),
                  static_cast<std::streamsize>(encrypted.size()))) {
    throw std::runtime_error("identity ciphertext could not be read");
  }

  DATA_BLOB source{static_cast<DWORD>(encrypted.size()), encrypted.data()};
  DATA_BLOB clear{};
  DATA_BLOB entropy = Entropy();
  if (!CryptUnprotectData(&source, nullptr, &entropy, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &clear)) {
    throw std::runtime_error("identity ciphertext could not be decrypted");
  }
  std::string value(reinterpret_cast<char*>(clear.pbData), clear.cbData);
  LocalFree(clear.pbData);
  if (value.empty()) {
    throw std::runtime_error("identity payload is empty");
  }
  return value;
}

void WriteIdentity(const std::string& value) {
  if (value.empty() || value.size() > kMaxIdentityBytes) {
    throw std::runtime_error("identity payload has an invalid size");
  }
  DATA_BLOB source{static_cast<DWORD>(value.size()),
                   reinterpret_cast<BYTE*>(const_cast<char*>(value.data()))};
  DATA_BLOB encrypted{};
  DATA_BLOB entropy = Entropy();
  if (!CryptProtectData(&source, L"NearSend identity", &entropy, nullptr,
                        nullptr, CRYPTPROTECT_UI_FORBIDDEN, &encrypted)) {
    throw std::runtime_error("identity payload could not be encrypted");
  }

  const std::filesystem::path path = IdentityPath();
  if (path.empty()) {
    LocalFree(encrypted.pbData);
    throw std::runtime_error("identity directory is unavailable");
  }
  std::filesystem::create_directories(path.parent_path());
  const std::filesystem::path temporary = path.wstring() + L".tmp";
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    LocalFree(encrypted.pbData);
    throw std::runtime_error("identity ciphertext could not be created");
  }
  DWORD written = 0;
  const BOOL wrote = WriteFile(file, encrypted.pbData, encrypted.cbData,
                               &written, nullptr);
  const BOOL flushed = wrote && written == encrypted.cbData && FlushFileBuffers(file);
  CloseHandle(file);
  LocalFree(encrypted.pbData);
  if (!flushed ||
      !MoveFileExW(temporary.c_str(), path.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temporary.c_str());
    throw std::runtime_error("identity ciphertext could not be committed");
  }
}

std::string Argument(const flutter::MethodCall<EncodableValue>& call,
                     const char* name) {
  const auto* arguments = std::get_if<EncodableMap>(call.arguments());
  if (arguments == nullptr) return {};
  const auto found = arguments->find(EncodableValue(name));
  if (found == arguments->end()) return {};
  const auto* value = std::get_if<std::string>(&found->second);
  return value == nullptr ? std::string() : *value;
}

}  // namespace

void RegisterPlatformIdentityChannel(flutter::FlutterEngine* engine) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        try {
          if (call.method_name() == "readIdentity") {
            const auto value = ReadIdentity();
            value.has_value() ? result->Success(EncodableValue(*value))
                              : result->Success();
            return;
          }
          if (call.method_name() == "writeIdentity") {
            WriteIdentity(Argument(call, "value"));
            result->Success();
            return;
          }
          result->NotImplemented();
        } catch (const std::exception&) {
          result->Error("NS-IDENTITY", "secure identity operation failed");
        }
      });
}
