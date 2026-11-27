#pragma once

#include <optional>
#include <string>

namespace profile_credential {
enum class Status { unavailable, available, enrolled };
struct Secret {
  std::string device;
  std::string passphrase;
};

Status GetStatus(const std::wstring& target);
bool Save(const std::wstring& target, const Secret& secret);
std::optional<Secret> Read(const std::wstring& target);
bool Forget(const std::wstring& target);
}  // namespace profile_credential
