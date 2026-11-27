#include "profile_credential.h"

#include <windows.h>
#include <objbase.h>
#include <string>

int main() {
  GUID guid;
  wchar_t tag[39];
  if (FAILED(CoCreateGuid(&guid)) || !StringFromGUID2(guid, tag, 39)) return 1;
  const std::wstring base = std::wstring(L"SecureMesh/Test/") + tag;
  const std::wstring a = base + L"/A", b = base + L"/B";
  struct Cleanup {
    const std::wstring& a;
    const std::wstring& b;
    ~Cleanup() { profile_credential::Forget(a); profile_credential::Forget(b); }
  } cleanup{a, b};
  using namespace profile_credential;
  const Secret first{"44f65abc-7b2b-4481-a2b0-b3f0988b1751", "test credential A"};
  const Secret second{"226463ef-a2e1-4a04-b89c-b80f9f748327", "test credential B"};
  if (GetStatus(a) != Status::available || !Save(a, first) || !Save(b, second)) return 2;
  const auto opened = Read(a);
  if (!opened || opened->device != first.device || opened->passphrase != first.passphrase) return 3;
  if (!Forget(a) || Read(a) || GetStatus(a) != Status::available) return 4;
  const auto other = Read(b);
  return other && other->device == second.device && other->passphrase == second.passphrase ? 0 : 5;
}
