#ifndef SECUREMESH_CLIPBOARD_PHOTO_H_
#define SECUREMESH_CLIPBOARD_PHOTO_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

void RegisterClipboardPhoto(flutter::BinaryMessenger* messenger, HWND window);

#endif
