# fqapp → iOS 移植方案

> 目标：无 Mac、GitHub Actions 出 IPA、LiveContainer 自签安装。
> 基于 `xwtc/fqapp-ios` 的 `master`（与上游 `08eea2a` 一致）勘察。
> 版本号已从仓库现有的 `android-apk.yml` 核实，不是猜测。

---

## 0. 两个决定性的发现

### 发现一：Dart 只调用 9 个 FFI 函数

`lib/src/rust/frb_generated.dart` 里的全部 API：

```
init / shutdown / status / base_url / session_capability
request / cancel / set_device_pool_key / version
```

`ApiClient` 的所有业务请求都收敛成一个
`request(requestId, method, path, query, body, timeoutMs)` 转发给 Rust，
由 Rust 完成签名、设备池、上游请求、解密。

**这意味着不需要把几十个 HTTP 端点搬到 iOS。** 让这一个函数在 iOS 上跑通，
所有在线功能就都通了。移植面比预想小得多。

### 发现二：FRB 2.13 在 iOS 上不认静态库

读 `frb_dart/lib/src/loader/_io.dart` 确认：

```dart
if (Platform.isIOS || Platform.isMacOS) {
  return tryAssumingNonPackaged(
    'lib$stem.dylib',
    (debugInfo) => _tryOpen(
      'rust_builder.framework/rust_builder',
      (debugInfo) => ExternalLibrary.open('$stem.framework/$stem', ...),
    ),
  );
}
```

只认动态框架。静态链接后这个查找必然失败。

但 `ExternalLibrary.process(iKnowHowToUseIt: true)` 是公开逃生舱，
返回 `DynamicLibrary.process()`（主二进制符号表）。而 `RustLib.init()`
所在的 `backend_transport.dart` 是**手写文件**，不是 `@generated`，
打补丁安全，下次 codegen 不会冲突。

---

## 1. 已核实的版本（来自仓库 android-apk.yml）

| 工具 | 版本 | 来源 |
|---|---|---|
| Flutter | **3.44.6** | `env.FLUTTER_VERSION` |
| Rust | **1.99.1** | `dtolnay/rust-toolchain` 的 `toolchain` |
| flutter_rust_bridge | **2.13.0** | `env.FRB_VERSION` |
| JDK | 17 | `setup-java` |
| Node | 22 | `setup-node` |

iOS 工作流与这些保持一致，避免出现"两套工具链"。

---

## 2. 现状判定

| 事实 | 依据 | 影响 |
|---|---|---|
| 无 `ios/` 目录 | 仓库根目录 | 需 `flutter create --platforms=ios` |
| UI 为 Flutter | `pubspec.yaml`、`lib/` | 跨平台复用，零成本 |
| 核心为 Rust 进程内库 | `rust/Cargo.toml`（含 `staticlib`） | 可静态链接 |
| 解密核心为纯 C | `native/crypto_core/*.c` | 可交叉编译；仅 `jni_bridge.c` 需重写 |
| 平台层约 220KB Kotlin | `android/app/src/main/kotlin/` | **主要成本** |
| Rust 源码结构清晰 | `rust/src/{api,dispatch,endpoints,upstream,sign,device}` | 无平台特定代码，移植友好 |

`rust/src/` 下没有任何 Android 专属模块，`android_logger` 是
`[target.'cfg(target_os = "android")'.dependencies]` 的条件依赖，
iOS 下自动不参与编译。**Rust 侧预期零改动。**

### 平台插件工作量清单

| Kotlin 文件 | 大小 | iOS 策略 |
|---|---|---|
| `NativePlayerPlugin.kt` | 53.8K | **重写**：AVPlayer + CENC（阶段 3） |
| `FloatingVideoService.kt` | 27.8K | **丢弃**：iOS 无悬浮窗 |
| `CryptoNative.kt` | 25.3K | **重写桥接**：C 核心保留，改 `.mm` 直接调 |
| `ReaderDevicePlugin.kt` | 16.5K | **重写**：`UIScreen.brightness`；音量键降级 |
| `FanqieAccountPlugin.kt` | 15.8K | **重写**：`WKWebView` |
| `ListenKeepAliveService.kt` | 15.0K | **重写**：`AVAudioSession` + 后台音频 |
| `LibraryBackupPlugin.kt` | 14.6K | **重写**：`UIDocumentPickerViewController` |
| `SystemTtsPlugin.kt` | 12.0K | **重写**：`AVSpeechSynthesizer` |
| `LocalBookPickerPlugin.kt` | 7.4K | **重写**：`UIDocumentPickerViewController` |
| `FairMemoryPlugin.kt` | 6.8K | **丢弃**：小米专属 |
| `DownloadsPlugin.kt` | 5.4K | **重写**：`URLSession` |
| `EinkRefreshPlugin.kt` | 2.6K | **丢弃**：纯 Android |
| `SharePlugin.kt` | 2.1K | **重写**：`UIActivityViewController` |
| `ReaderBrightnessSession.kt` | 1.6K | 同亮度 |
| `ReaderSystemBarsSession.kt` | 1.2K | **重写**：`prefersStatusBarHidden` |

---

## 3. 阶段 0：能装、能起

### 3.1 三个关键改动

**改动一：生成 iOS 工程**

```bash
flutter create --platforms=ios --org com.fqapp --project-name fqapp .
```

**改动二：静态链接（`-force_load`）**

不用 podspec，直接往 `ios/Flutter/Release.xcconfig` 追加：

```
OTHER_LDFLAGS = $(inherited) -Wl,-force_load,$(SRCROOT)/../rust/target/aarch64-apple-ios/release/libfqapi_core.a
```

理由：
- `$(SRCROOT)` 由 Xcode 求值，对 Runner target 是 `ios/`，`../rust/...` 指向仓库根
- `-Wl,-force_load,<path>` 是**单个 token**，路径含空格也不会被拆开
- 不经过 CocoaPods 沙箱，少一层路径解析失败的可能

`-force_load` 不可省：Dart 只用 FFI 按名字查符号，链接器看不到静态引用，
默认会把整个 `.a` 当死代码剥掉。

**改动三：FRB 加载补丁**

`lib/services/backend_transport.dart` 改 3 处：

```dart
import 'dart:io' show Platform;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';

static Future<void> ensureRuntime() =>
    _runtimeReady ??= RustLib.init(
      externalLibrary: _externalLibraryForPlatform(),
    );

static ExternalLibrary? _externalLibraryForPlatform() {
  if (Platform.isIOS) {
    return ExternalLibrary.process(iKnowHowToUseIt: true);
  }
  return null;
}
```

`frb_generated.dart` **一行都不用改**：`defaultExternalLibraryLoaderConfig`
只在 `externalLibrary == null` 时才会被使用，显式传入后默认加载器整个被跳过。

CI 里用 Python 脚本自动应用，并用 `grep` 校验确实生效。

### 3.2 提前失败机制

工作流里这步是核心：

```bash
nm -gU build/ios/iphoneos/Runner.app/Runner | grep -q "frb_get_rust_content_hash"
```

链接后立刻检查主二进制。**不用装机就能知道成没成**：
若 `-force_load` 没生效，5 分钟内 fail 并打印链接参数和实际符号表。

### 3.3 出未签名 IPA

`flutter build ios --release --no-codesign` → `Runner.app` 塞进 `Payload/` → zip 改名 `.ipa`。

不做 codesign：LiveContainer 安装时用自己的证书重签。

---

## 4. 阶段 1：阅读线（3–5 天）

几乎不依赖 Android 原生代码，**优先做**。

覆盖：搜索、详情、目录、正文阅读、书架、历史、章节缓存、备份恢复。

| 调用点 | iOS 替代 |
|---|---|
| `path_provider` | ✅ 插件自带 |
| `shared_preferences` | ✅ 插件自带 |
| `hive_ce` | ✅ 纯 Dart |
| `connectivity_plus` | ✅ 插件自带 |
| `url_launcher` | ✅ 插件自带 |
| `flutter_secure_storage` | ⚠️ Keychain，见 §6.1 |
| `fqapp/share` | 需实现 `shareText` |
| 字体导入 | 需文件选择器 |
| 亮度调节 | 需实现 |
| 状态栏隐藏 | 需实现 |

**阶段 1 完成即为可用产品**（能看小说、能缓存、能离线）。

---

## 5. 阶段 2：听书（2–3 天）

- 播放：`AVPlayer`
- 后台：`UIBackgroundModes: [audio]` + `AVAudioSession.playback`（CI 已写入）
- 锁屏控制：`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`
- 耳机拔出：`AVAudioSession.routeChangeNotification`
- 字幕时间轴：数据来自 Rust，**Dart 逻辑可直接复用**

**LiveContainer 风险**：免费证书下后台执行不稳定，需实测；不可用则降级为仅前台。

---

## 6. 阶段 3：短剧/漫剧（1–2 周，风险最高）

### 现状

1. Rust 返回流地址 + 内容密钥（`/api/content?mode=stream`）
2. `CryptoNative.kt` → JNI → `native/crypto_core/mp4_cenc.c` 边读边解
3. 自定义 `DataSource` 喂 ExoPlayer
4. `SurfaceProducer` 输出到 Flutter `Texture`

### iOS 三方案

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A（推荐）** | `AVAssetResourceLoaderDelegate` 拦截请求，解密后喂 AVPlayer | 保留流式与拖动 | 需处理 init segment 与 range 语义 |
| B | 整段解密落盘再播 | 最简单 | 失去流式，长视频不可接受 |
| C | VideoToolbox + `AVSampleBufferDisplayLayer` | 最灵活 | 工作量以周计 |

### 渲染层

Android 用 `Texture(textureId:)`，iOS 必须改成 `UiKitView` + `AVPlayerLayer`。
`native_player.dart`（700+ 行）要抽平台抽象：

```dart
abstract class PlatformPlayer {
  Future<int> create(String url, String keyHex);
  Stream<Duration> get positionStream;
  Widget buildSurface();  // Android: Texture, iOS: UiKitView
}
```

其状态机（`_dispatchEvent` 的 pending 缓冲那套）设计得不错，抽象时保留，只换通道实现。

---

## 7. LiveContainer 自签的四个坑

### 7.1 7 天证书 vs Keychain（最严重）

`EncryptedHive` 把 Hive 密钥存在 `flutter_secure_storage`（iOS 走 Keychain）。

免费证书 7 天过期，重签后 entitlements 可能变化，导致 `kSecAttrAccessGroup` 失配：
**密钥读不到 → Hive 打不开 → 书架/历史全丢**。

**建议**：在 `secure_key_provider.dart` 加降级——读不到时不要直接失败，
提示"证书已更换，本地数据需重建"，并保留只读的备份导出通道。

### 7.2 后台播放

见 §5。`UIBackgroundModes: audio` 已在 CI 写入，实际能否后台运行需实测。

### 7.3 悬浮窗

`FloatingVideoService.kt`（27.8K）整块丢弃，iOS 无对应 API。

### 7.4 音量键翻页

iOS 无法可靠拦截硬件音量键（`MPVolumeView` 方案在 iOS 15+ 已不可靠）。
`volume_key.dart` 在 iOS 上应直接禁用。

---

## 8. 执行顺序

1. **先跑阶段 0**。`nm` 校验能立刻告诉你静态链接是否成功，
   不需要装机就能验证——这是整个方案最大的不确定性。
2. 阶段 1 阅读线 → 可用产品
3. 阶段 2 听书
4. 阶段 3 视频，视需求决定

如果静态链接走不通，退路是构建 `fqapi_core.framework` 动态框架（FRB 官方路线），
代价是 LiveContainer 重签时要一并处理嵌套 framework。

---

## 9. 未验证项（诚实标注）

以下内容**没有**在真实 macOS 环境验证过，需首次 CI 运行后修正：

- ⚠️ `-force_load` 经 `OTHER_LDFLAGS` 传入时，Xcode 对 `$(SRCROOT)` 的求值时机
- ⚠️ Rust 1.99.1 交叉编译到 `aarch64-apple-ios` 时 `ring` 的汇编是否正常
  （`rustls` 用 `ring`，iOS 需汇编；通常能过，但这是静态链接后最可能出问题的地方）
- ⚠️ 静态链接后 `reqwest`/`tokio` 在 iOS 的运行时行为（尤其 `net` feature 的 socket）
- ⚠️ CENC 在 AVPlayer 下的可行性（方案 A 未做原型）
- ⚠️ LiveContainer 重签后 Keychain 的实际行为
- ⚠️ 视频解密到底在 Rust 还是 C：`DEVELOPMENT.md` 说小说插图解密在 Rust，
  视频流解密在 `CryptoNative.kt`。边界需读 `rust/src/endpoints/base.rs` 确认
