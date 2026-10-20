// Registers the native player plugin with the Flutter engine.
//
// This file is injected by CI after `flutter create` generates ios/. Keeping it
// separate from AppDelegate.swift means the generated file stays untouched, and
// the patch below is a single anchored insert rather than a rewrite.
//
// The plugin is registered explicitly instead of through GeneratedPluginRegistrant
// because it lives in the Runner target (it needs the app's own bundle id for
// nothing, but it does need to be compiled into Runner.app), not in a pod.

import Flutter
import UIKit

enum NativePlayerRegistrar {
  static func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "NativePlayerPlugin") else {
      return
    }
    NativePlayerPlugin.register(with: registrar)
  }
}
