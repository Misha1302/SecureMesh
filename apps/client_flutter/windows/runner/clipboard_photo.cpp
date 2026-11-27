#include "clipboard_photo.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <cstdint>
#include <memory>
#include <vector>

void RegisterClipboardPhoto(flutter::BinaryMessenger* messenger, HWND window) {
  flutter::MethodChannel<flutter::EncodableValue> channel(
      messenger, "securemesh/clipboard-photo", &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([window](const auto& call, auto result) {
    if (call.method_name() != "read") { result->NotImplemented(); return; }
    // Use encoded PNG; DIB handles and file/URL references are not encoded images.
    const UINT format = RegisterClipboardFormatW(L"PNG");
    if (!format || !IsClipboardFormatAvailable(format)) { result->Success(); return; }
    if (!OpenClipboard(window)) { result->Error("unavailable"); return; }
    struct ClipboardGuard { ~ClipboardGuard() { CloseClipboard(); } } guard;
    HANDLE value = GetClipboardData(format);
    const SIZE_T size = value ? GlobalSize(value) : 0;
    if (!size || size > 4 * 1024 * 1024) { result->Error("size"); return; }
    const auto* bytes = static_cast<const uint8_t*>(GlobalLock(value));
    if (!bytes) { result->Error("unavailable"); return; }
    std::vector<uint8_t> copied(bytes, bytes + size);
    GlobalUnlock(value);
    result->Success(flutter::EncodableValue(std::move(copied)));
  });
}
