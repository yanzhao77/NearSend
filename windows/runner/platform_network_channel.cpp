#include "platform_network_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <windows.h>

#include <memory>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kChannelName[] = "com.nearsend.app/network";

EncodableMap Capabilities() {
  // Automatic joining stays disabled until Native Wi-Fi completion events,
  // profile ownership and cleanup are verified on a Windows host.
  return EncodableMap{
      {EncodableValue("canHostLocalOnlyHotspot"), EncodableValue(false)},
      {EncodableValue("canJoinWifi"), EncodableValue(false)},
      {EncodableValue("joinRequiresSystemApproval"), EncodableValue(true)},
  };
}

bool OpenWifiSettings() {
  const auto result = reinterpret_cast<INT_PTR>(::ShellExecuteW(
      nullptr, L"open", L"ms-settings:network-wifi", nullptr, nullptr,
      SW_SHOWNORMAL));
  return result > 32;
}

}  // namespace

void RegisterPlatformNetworkChannel(flutter::FlutterEngine* engine) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == "capabilities") {
          result->Success(EncodableValue(Capabilities()));
          return;
        }
        if (call.method_name() == "openWifiSettings") {
          if (OpenWifiSettings()) {
            result->Success();
          } else {
            result->Error("NS-NETWORK-UNAVAILABLE",
                          "Windows Wi-Fi settings could not be opened");
          }
          return;
        }
        if (call.method_name() == "startLocalOnlyHotspot" ||
            call.method_name() == "stopLocalOnlyHotspot" ||
            call.method_name() == "joinWifi" ||
            call.method_name() == "releaseJoinedWifi") {
          result->Error("NS-NETWORK-UNSUPPORTED",
                        "automatic Windows network bootstrap is unavailable");
          return;
        }
        result->NotImplemented();
      });
}
