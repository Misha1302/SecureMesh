#include "profile_credential_channel.h"
#include "profile_credential.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>

namespace {
using flutter::EncodableValue;
using flutter::EncodableMap;
const std::string* Field(const EncodableMap& fields, const std::string& key) {
  const auto it = fields.find(EncodableValue(key));
  return it == fields.end() ? nullptr : std::get_if<std::string>(&it->second);
}
}  // namespace

void RegisterProfileCredential(flutter::BinaryMessenger* messenger) {
  flutter::MethodChannel<> channel(messenger, "securemesh/windows-profile",
                                   &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([](const auto& call, auto result) {
    const auto* fields = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    const auto* id = fields ? Field(*fields, "id") : nullptr;
    if (!id || id->size() != 64 || id->find_first_not_of("0123456789abcdef") != std::string::npos) {
      result->Error("profile");
      return;
    }
    const std::wstring target = L"SecureMesh/Profile/v1/" + std::wstring(id->begin(), id->end());
    const auto& op = call.method_name();
    if (op == "status") {
      const auto state = profile_credential::GetStatus(target);
      const char* value = state == profile_credential::Status::enrolled ? "enrolled" :
                          state == profile_credential::Status::available ? "available" : "unavailable";
      result->Success(EncodableValue(std::string(value)));
    } else if (op == "forget") {
      if (profile_credential::Forget(target)) result->Success(); else result->Error("credential");
    } else if (op == "enable") {
      const auto* device = Field(*fields, "deviceId");
      const auto* pass = Field(*fields, "passphrase");
      if (device && pass && profile_credential::Save(target, {*device, *pass})) result->Success();
      else result->Error("credential");
    } else if (op == "unlock") {
      const auto secret = profile_credential::Read(target);
      if (!secret) { result->Error("credential"); return; }
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("deviceId"), EncodableValue(secret->device)},
          {EncodableValue("passphrase"), EncodableValue(secret->passphrase)}}));
    } else {
      result->NotImplemented();
    }
  });
}
