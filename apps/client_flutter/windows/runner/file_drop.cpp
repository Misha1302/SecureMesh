#include "file_drop.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <string>

void ReceiveFileDrop(flutter::BinaryMessenger* messenger, HDROP drop) {
  struct DropOwner {
    HDROP value;
    ~DropOwner() { DragFinish(value); }
  } owner{drop};
  const UINT count = DragQueryFileW(drop, 0xffffffff, nullptr, 0);
  if (!count || count > 8) return;
  flutter::EncodableList paths;
  for (UINT i = 0; i < count; ++i) {
    const UINT size = DragQueryFileW(drop, i, nullptr, 0);
    if (size < 4 || size > 32767) return;
    std::wstring path(size + 1, L'\0');
    if (DragQueryFileW(drop, i, path.data(), size + 1) != size ||
        path[1] != L':' || path[2] != L'\\') return;
    const std::wstring root = path.substr(0, 3);
    const UINT drive = GetDriveTypeW(root.c_str());
    if (drive != DRIVE_FIXED && drive != DRIVE_REMOVABLE) return;
    const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(),
                                          size, nullptr, 0, nullptr, nullptr);
    if (!length) return;
    std::string utf8(length, '\0');
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.data(), size,
                             utf8.data(), length, nullptr, nullptr)) return;
    paths.emplace_back(utf8);
  }
  flutter::MethodChannel<> channel(messenger, "securemesh/file-drop",
                                    &flutter::StandardMethodCodec::GetInstance());
  channel.InvokeMethod("drop", std::make_unique<flutter::EncodableValue>(paths));
}
