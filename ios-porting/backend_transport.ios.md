// ============================================================================
// backend_transport.dart 的 iOS 静态链接补丁
// ============================================================================
//
// 背景：
//   flutter_rust_bridge 2.13 的默认 iOS 加载器只认 `{stem}.framework/{stem}`
//   这种「动态框架」，见 frb_dart/lib/src/loader/_io.dart：
//
//     if (Platform.isIOS || Platform.isMacOS) {
//       return tryAssumingNonPackaged(
//         'lib$stem.dylib',
//         (debugInfo) => _tryOpen(
//           'rust_builder.framework/rust_builder', ...  // 模板脚手架
//           (debugInfo) => ExternalLibrary.open('$stem.framework/$stem', ...),
//         ),
//       );
//     }
//
//   而 iOS 侧载（LiveContainer 重签）用静态库更稳：单一二进制、没有嵌套
//   framework 需要单独重签、也不会遇到 dlopen 路径问题。
//
//   ExternalLibrary.process(iKnowHowToUseIt: true) 是 FRB 的公开逃生舱，
//   它返回 DynamicLibrary.process()，即「在主二进制的符号表里查找」。
//
// 需要改的地方只有一处：RustBackendTransport.ensureRuntime()
// 这个文件是手写的（不是 @generated），可以放心改。
//
// ---------------------------------------------------------------------------
// 改动 1：文件顶部 import 区，在现有 import 之后追加
// ---------------------------------------------------------------------------
//
//   import 'dart:io' show Platform;
//   import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
//
// 说明：
//   - `dart:io` 的 Platform 用来区分 iOS；如果不想引入，也可以用
//     `defaultTargetPlatform == TargetPlatform.iOS`（需要 flutter/foundation）。
//   - `flutter_rust_bridge_for_generated_io.dart` 导出 ExternalLibrary。
//     用这个而不是 `flutter_rust_bridge.dart`，是因为后者在 Web 下会被
//     条件导入替换，而本文件只服务于 IO 平台。
//
// ---------------------------------------------------------------------------
// 改动 2：替换 ensureRuntime()
// ---------------------------------------------------------------------------
//
// 原代码：
//
//   /// Loads the bridge runtime once per process.
//   static Future<void> ensureRuntime() => _runtimeReady ??= RustLib.init();
//
// 改为：
//
//   /// Loads the bridge runtime once per process.
//   ///
//   /// iOS 上 Rust 核心是**静态链接**进 Runner 主二进制的（见
//   /// .github/workflows/ios-ipa.yml 的 -force_load），没有任何独立的
//   /// dylib/framework 可 open，因此必须用 process() 在主二进制符号表里
//   /// 查找。其他平台沿用 FRB 默认加载器。
//   static Future<void> ensureRuntime() => _runtimeReady ??= RustLib.init(
//     externalLibrary: _externalLibraryForPlatform(),
//   );
//
//   static ExternalLibrary? _externalLibraryForPlatform() {
//     if (Platform.isIOS) {
//       // iKnowHowToUseIt 是 FRB 要求显式确认的开关：只有本进程内
//       // 不存在第二个使用 flutter_rust_bridge 的包时才安全。
//       // 本 App 只有 fqapi_core 一个 FRB 使用者。
//       return ExternalLibrary.process(iKnowHowToUseIt: true);
//     }
//     return null; // Android/桌面/测试：交给 FRB 默认加载器
//   }
//
// ---------------------------------------------------------------------------
// 为什么不需要改 frb_generated.dart
// ---------------------------------------------------------------------------
//
//   frb_generated.dart 里的 `defaultExternalLibraryLoaderConfig` 只在
//   `initImpl` 收到 `externalLibrary == null` 时才会被使用：
//
//     externalLibrary ??= await _loadDefaultExternalLibrary();
//
//   我们显式传了 externalLibrary，默认加载器整个被跳过，
//   frb_generated.dart 保持原样，下次 codegen 也不会冲突。
//
// ---------------------------------------------------------------------------
// 验证点（首次 CI 跑完后检查）
// ---------------------------------------------------------------------------
//
//   1. 链接阶段成功，说明 -force_load 生效且符号存在。
//      若报 `Undefined symbols: _frb_get_rust_content_hash` 之类，
//      说明 -force_load 路径没匹配上。
//
//   2. App 启动后进入「正在启动本地服务...」并最终进主界面，
//      说明 RustLib.init() 找到了符号。
//
//   3. 若启动即崩在 RustLib.init()，看 Xcode/Console 日志：
//      - `Failed to lookup symbol 'frb_get_rust_content_hash'`
//        → 符号没链进来，检查 force_load
//      - 崩在 Rust 内部（SIGABRT + panic 信息）
//        → 可能是 iOS 下某个 crate 不支持，需逐个排查
//
// ---------------------------------------------------------------------------
// 备选方案（若静态链接走不通）
// ---------------------------------------------------------------------------
//
//   退回 FRB 官方路线：构建动态框架 fqapi_core.framework，放进
//   ios/Frameworks/ 并设为 Embed & Sign。此时不需要本补丁，
//   RustLib.init() 保持无参调用。代价是 LiveContainer 重签时必须
//   一并重签嵌套 framework，失败率高一些。
//
//   构建方式（CI）：
//     cd rust
//     cargo rustc --release --target aarch64-apple-ios \
//       --crate-type cdylib \
//       -- -C link-arg=-install_name -C link-arg=@rpath/fqapi_core.framework/fqapi_core
//     再手工组装 .framework 目录（Info.plist + 二进制 + Modules）。
//   这条路线没有现成脚本，需要额外 30–60 分钟调试。
