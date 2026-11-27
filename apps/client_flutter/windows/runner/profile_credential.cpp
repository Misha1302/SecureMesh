#include "profile_credential.h"

#include <windows.h>
#include <wincred.h>
#include <wincrypt.h>

#include <algorithm>
#include <vector>

namespace profile_credential {
namespace {
struct Credential {
  PCREDENTIALW value = nullptr;
  ~Credential() { if (value) CredFree(value); }
};

struct ProtectedData {
  DATA_BLOB value{};
  ~ProtectedData() {
    if (value.pbData) {
      SecureZeroMemory(value.pbData, value.cbData);
      LocalFree(value.pbData);
    }
  }
};

DATA_BLOB PathBinding(const std::wstring& target) {
  return {static_cast<DWORD>(target.size() * sizeof(wchar_t)),
          reinterpret_cast<BYTE*>(const_cast<wchar_t*>(target.data()))};
}

bool ValidDevice(const std::string& device) {
  if (device.size() != 36) return false;
  for (size_t i = 0; i < device.size(); ++i) {
    const char c = device[i];
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (c != '-') return false;
    } else if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f')) {
      return false;
    }
  }
  return true;
}
}  // namespace

Status GetStatus(const std::wstring& target) {
  Credential item;
  if (CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &item.value)) return Status::enrolled;
  return GetLastError() == ERROR_NOT_FOUND ? Status::available : Status::unavailable;
}

bool Save(const std::wstring& target, const Secret& secret) {
  if (!ValidDevice(secret.device) || secret.passphrase.empty() ||
      secret.passphrase.size() > CRED_MAX_CREDENTIAL_BLOB_SIZE ||
      GetStatus(target) != Status::available) return false;
  std::vector<BYTE> plain(secret.device.begin(), secret.device.end());
  plain.insert(plain.end(), secret.passphrase.begin(), secret.passphrase.end());
  DATA_BLOB input{static_cast<DWORD>(plain.size()), plain.data()};
  auto binding = PathBinding(target);
  ProtectedData cipher;
  const BOOL ok = CryptProtectData(&input, nullptr, &binding, nullptr, nullptr,
                                   CRYPTPROTECT_UI_FORBIDDEN, &cipher.value);
  SecureZeroMemory(plain.data(), plain.size());
  if (!ok || cipher.value.cbData > CRED_MAX_CREDENTIAL_BLOB_SIZE) return false;
  CREDENTIALW credential{};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName = const_cast<wchar_t*>(target.c_str());
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
  credential.CredentialBlob = cipher.value.pbData;
  credential.CredentialBlobSize = cipher.value.cbData;
  return CredWriteW(&credential, 0) != FALSE;
}

std::optional<Secret> Read(const std::wstring& target) {
  Credential item;
  if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &item.value)) return std::nullopt;
  DATA_BLOB cipher{item.value->CredentialBlobSize, item.value->CredentialBlob};
  ProtectedData plain;
  auto binding = PathBinding(target);
  if (!CryptUnprotectData(&cipher, nullptr, &binding, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &plain.value) ||
      plain.value.cbData <= 36) return std::nullopt;
  const char* data = reinterpret_cast<const char*>(plain.value.pbData);
  Secret secret{std::string(data, 36), std::string(data + 36, plain.value.cbData - 36)};
  if (!ValidDevice(secret.device)) return std::nullopt;
  return secret;
}

bool Forget(const std::wstring& target) {
  return CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) || GetLastError() == ERROR_NOT_FOUND;
}
}  // namespace profile_credential
