#ifndef RUNNER_PLATFORM_STORAGE_CHANNEL_H_
#define RUNNER_PLATFORM_STORAGE_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

void RegisterPlatformStorageChannel(flutter::FlutterEngine* engine,
                                    HWND parent_window);

#endif  // RUNNER_PLATFORM_STORAGE_CHANNEL_H_
