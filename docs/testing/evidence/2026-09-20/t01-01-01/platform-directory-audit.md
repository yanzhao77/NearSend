# 平台目录审计：确认没有业务逻辑进入 `android/`、`windows/`、`ios/`

- 运行 ID：`t01-01-01`
- 任务：T01-01
- 目的：核对 `AGENTS.md` §4「平台目录只负责系统 API 和资源生命周期适配，不复制应用业务流程」
  与 T01-01 验收条件「没有业务逻辑放入平台目录」。
- 方法：把仓库中的平台目录与 `flutter create` 的**原始生成结果**按文件逐个做 SHA-256 比对。
- 原始数据：`platform-diff.json`

## 1. 比对基线

```text
flutter create --org com.nearsend --project-name nearsend \
  --platforms=android,windows,ios \
  --description "NearSend - reliable offline large-file transfer between phone and PC over local Wi-Fi." \
  <临时目录>
```

生成结果保留在临时目录中不再改动，作为比对基线。比对时排除
`build/`、`.gradle/`、`.dart_tool/`、`ephemeral/`、`xcuserdata/`、`.idea/` 这些生成物或本机状态。

## 2. 结果

| 平台 | 仓库文件数 | 基线文件数 | 新增 | 删除 | 修改 |
| --- | --- | --- | --- | --- | --- |
| android | 25 | 25 | 1 | 1 | 3 |
| windows | 18 | 18 | 0 | 0 | 2 |
| ios | 44 | 44 | 0 | 0 | 2 |

### android

| 差异 | 文件 | 内容 | 性质 |
| --- | --- | --- | --- |
| 新增 | `app/src/main/kotlin/com/nearsend/app/MainActivity.kt` | 空 `FlutterActivity` 子类，包名 `com.nearsend.app` | 标识 |
| 删除 | `app/src/main/kotlin/com/nearsend/nearsend/MainActivity.kt` | 包名 `com.nearsend.nearsend` | 标识 |
| 修改 | `app/build.gradle.kts` | `namespace` 与 `applicationId` 改为 `com.nearsend.app` | 标识 |
| 修改 | `app/src/main/AndroidManifest.xml` | `android:label` 改为 `NearSend` | 标识 |
| 修改 | `local.properties` | 本机 SDK 路径，由构建工具生成，已被 `android/.gitignore` 忽略 | 本机状态，不入库 |

新增/删除各 1 个文件是同一个 `MainActivity.kt` 的**包路径迁移**，不是新逻辑。

### windows

| 差异 | 文件 | 内容 | 性质 |
| --- | --- | --- | --- |
| 修改 | `runner/main.cpp` | 窗口标题 `L"nearsend"` → `L"NearSend"` | 标识 |
| 修改 | `runner/Runner.rc` | `FileDescription`、`ProductName` → `NearSend` | 标识 |

未改动 `InternalName`、`OriginalFilename`、`CompanyName`（分别是二进制名与组织标识）。

### ios

| 差异 | 文件 | 内容 | 性质 |
| --- | --- | --- | --- |
| 修改 | `Runner/Info.plist` | `CFBundleDisplayName` → `NearSend` | 标识 |
| 修改 | `Runner.xcodeproj/project.pbxproj` | 6 处 `PRODUCT_BUNDLE_IDENTIFIER` → `com.nearsend.app`（含 3 处 `RunnerTests` 后缀） | 标识 |

## 3. 结论

- 三个平台目录相对 `flutter create` 原始生成结果**只存在标识类改动**（应用显示名、窗口标题、
  bundle/application id）以及本机生成的 `local.properties`。
- **没有任何新增的 Dart/Java/Kotlin/Swift/C++ 业务文件**，没有网络、存储、协议或状态机代码。
- 全部业务代码位于 `lib/`，按 `docs/architecture/APP_AND_SERVICE_DESIGN.md` §2 分层。

## 4. 需要注意的人工复核点

1. `applicationId` / bundle identifier 一旦在商店发布即不可更改。当前值 `com.nearsend.app`
   记录在 `docs/decisions/ADR-0001-工程基线与标识.md`，如需变更必须在 T10 之前完成并同步 ADR。
2. `flutter create` 默认会把 `--org` 与项目名拼接成 `com.nearsend.nearsend`；本次显式收敛为
   `com.nearsend.app`。后续若再执行 `flutter create` 覆盖，需要重新核对本文件。
3. Windows 的 `InternalName`/`OriginalFilename` 仍为 `nearsend`（与可执行文件名一致），
   这是有意保留的：它们描述二进制文件本身，而不是用户可见的产品名。
