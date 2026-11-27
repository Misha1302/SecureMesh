#pragma once
#include <windows.h>
#include <shellapi.h>
#include <flutter/binary_messenger.h>

void ReceiveFileDrop(flutter::BinaryMessenger* messenger, HDROP drop);
