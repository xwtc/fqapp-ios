// Registers the native player plugin with the Flutter engine.
//
// Injected by CI after `flutter create` generates ios/. Kept separate from
// AppDelegate.swift so the generated file only receives one anchored line.
//
// The parameter is typed FlutterPluginRegistry, which is what
// GeneratedPluginRegistrant takes, so whatever expression the template passes
// there also works here.

import Flutter
import UIKit

enum NativePlayerRegistrar {
  /// `registrarForPlugin:` is annotated `nullable` in FlutterPlugin.h, so Swift
  /// imports it as optional and the guard is required rather than defensive.
  static func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "NativePlayerPlugin") else {
      return
    }
    NativePlayerPlugin.register(with: registrar)
  }
}
