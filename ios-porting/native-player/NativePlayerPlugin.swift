// Native player host for iOS.
//
// Android uses ExoPlayer in NativePlayerPlugin.kt; iOS has no such plugin, so
// every playback entry point (listening, short drama, inline video) failed with
// MissingPluginException. This file implements the same MethodChannel and
// EventChannel contract on top of AVPlayer so the Dart side needs no change.
//
// Two differences from Android that shape the design:
//
//  1. CENC decryption is NOT done here. The Rust core already downloads the
//     encrypted MP4, decrypts it in place, and serves it from /src/ with Range
//     support (see rust/src/endpoints/video.rs). The Dart side resolves that
//     URL before calling create(), so this plugin only ever plays plain bytes.
//     Reimplementing the CENC walk in Swift would duplicate ~47 KB of C that is
//     already tested against golden vectors.
//
//  2. Flutter renders video through Texture(textureId:), so this class is a
//     FlutterTexture: AVPlayerItemVideoOutput hands us CVPixelBuffers and
//     Flutter copies them into its raster cache.

import AVFoundation
import Flutter
import UIKit

/// One AVPlayer plus the texture it feeds.
///
/// Ownership: the plugin owns instances and disposes them on `dispose` or on
/// `detachFromEngine`. Events are only delivered while `attachedToEngine`.
final class NativePlayerInstance: NSObject, FlutterTexture {
  let playerId: Int
  private let player: AVPlayer
  private let videoOutput: AVPlayerItemVideoOutput
  private let registry: FlutterTextureRegistry
  // FlutterEventSink is a closure, so it cannot be weak. The plugin owns the
  // sink and clears it in dispose(), which is what stops events from reaching a
  // torn-down engine.
  private var sink: FlutterEventSink?

  private(set) var textureId: Int64 = 0
  private var item: AVPlayerItem?
  private var displayLink: CADisplayLink?
  private var timeObserver: Any?

  private var firstFrameSent = false
  private var lastBuffering: Bool?
  private var lastPlaying: Bool?
  private var lastPlayWhenReady: Bool?
  private var lastDurationMs: Int64 = -1
  private var lastVideoSize: CGSize = .zero
  private var disposed = false
  /// A seek requested before the item was ready, applied on `.readyToPlay`.
  private var pendingSeekMs: Int64?

  // AVPlayerItem.status/loadedTimeRanges are KVO-observed; keep the tokens so
  // detach can remove exactly the observations this instance added.
  private var statusObservation: NSKeyValueObservation?
  private var bufferObservation: NSKeyValueObservation?
  private var rateObservation: NSKeyValueObservation?
  private var endObservation: NSObjectProtocol?

  init(
    playerId: Int,
    url: URL,
    registry: FlutterTextureRegistry,
    sink: @escaping FlutterEventSink
  ) {
    self.playerId = playerId
    self.registry = registry
    self.sink = sink

    // BGRA keeps the copy into Flutter a straight memcpy on every device; the
    // native YUV path is faster on paper but needs a per-device capability
    // check that is not worth the failure modes here.
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)

    let item = AVPlayerItem(url: url)
    item.add(videoOutput)
    self.item = item
    self.player = AVPlayer(playerItem: item)
    super.init()

    // Audio-only sources must keep playing when the screen locks: the app
    // declares UIBackgroundModes=audio and this session category is what makes
    // the OS honour it. `.playback` covers both the listening and video cases;
    // a specific mode would only matter for AirPlay/ducking behaviour we do not
    // use yet.
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      // A missing session only costs background playback; do not fail create.
    }

    player.actionAtItemEnd = .pause
    // Let AVPlayer pick its own buffering policy; ExoPlayer's equivalents have
    // no direct analogue and tuning them here caused stalls on short clips.

    textureId = registry.register(self)
    observeItem(item)
    startDisplayLink()
    emit("created", value: Int(textureId))
    // decoderInitialized mirrors the Android event the Dart side logs; there is
    // no decoder to report, but emitting it keeps the log shape identical.
    emit("decoderInitialized", extra: ["name": "AVPlayer", "mimeType": ""])
  }

  // MARK: - Playback control

  func play() {
    guard !disposed else { return }
    player.play()
    // setRate on a paused player only records the intent; apply it now that
    // playback is starting, otherwise a rate chosen before play would be lost.
    if pendingRate != 1, player.rate != pendingRate {
      player.rate = pendingRate
    }
    publishPlaying()
  }

  func pause() {
    guard !disposed else { return }
    player.pause()
    publishPlaying()
  }

  func seek(toMilliseconds ms: Int64) {
    guard !disposed else { return }
    let target = max(0, ms)
    // AVPlayer drops a seek issued before the item is ready: `create()` returns
    // as soon as the player exists, and the Dart side seeks immediately to
    // restore a saved position. Without this deferral the restore silently
    // lands on 0 and playback starts from the beginning.
    guard item?.status == .readyToPlay else {
      pendingSeekMs = target
      return
    }
    performSeek(target)
  }

  private func performSeek(_ ms: Int64) {
    pendingSeekMs = nil
    let time = CMTime(value: CMTimeValue(ms), timescale: 1000)
    // Zero tolerance: the Dart side treats the seek as acknowledged once the
    // call returns and rewrites its own position, so a loose tolerance would
    // make the reported position drift from the picture.
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      self?.publishPosition()
    }
  }

  func setVolume(_ volume: Float) {
    guard !disposed else { return }
    player.volume = max(0, min(1, volume))
  }

  func setRate(_ rate: Float) {
    guard !disposed else { return }
    // A non-zero rate while paused would start playback; only apply the rate
    // when the player is already running, and remember it for the next play.
    if player.rate != 0 {
      player.rate = rate
    } else {
      pendingRate = rate
    }
  }

  private var pendingRate: Float = 1

  // MARK: - Observation

  private func observeItem(_ item: AVPlayerItem) {
    statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard let self, !self.disposed else { return }
      switch item.status {
      case .readyToPlay:
        self.emit("buffering", value: false)
        self.publishDuration()
        self.publishVideoSize()
        // Apply a restore seek that arrived before the item was playable.
        if let pending = self.pendingSeekMs {
          self.performSeek(pending)
        }
      case .failed:
        self.emitError(item.error)
      default:
        break
      }
    }

    bufferObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
      guard let self, !self.disposed else { return }
      self.emitBuffering(item.isPlaybackBufferEmpty)
    }

    rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
      guard let self, !self.disposed else { return }
      // Do NOT write player.rate here: this observer fires on every rate
      // change, so re-applying the pending rate inside it would recurse.
      // pendingRate is applied by play(), which is the only place a paused
      // player legitimately starts.
      self.publishPlaying()
    }

    endObservation = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self, !self.disposed else { return }
      self.publishPosition()
      self.emit("completed", value: true)
      self.publishPlaying()
    }
  }

  private func startDisplayLink() {
    let link = CADisplayLink(target: self, selector: #selector(onFrame))
    // Default rate (the display's own refresh) is enough: Flutter samples the
    // newest buffer, so a lower cadence would only add latency, and tuning
    // preferredFrameRateRange buys nothing here.
    link.add(to: .main, forMode: .common)
    displayLink = link
  }
  @objc private func onFrame() {
    guard !disposed, let item else { return }
    let time = player.currentTime()
    // Pulling without a fresh frame returns the previous buffer, which would
    // keep re-uploading the same texture; only signal Flutter when the output
    // actually has a new one.
    if videoOutput.hasNewPixelBuffer(forItemTime: time) {
      registry.textureFrameAvailable(textureId)
      if !firstFrameSent {
        firstFrameSent = true
        emit("firstFrame", value: true)
        publishVideoSize()
      }
    }
    publishPosition()
    publishDuration()
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard !disposed else { return nil }
    let time = player.currentTime()
    guard let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
      return nil
    }
    return Unmanaged.passRetained(buffer)
  }

  // MARK: - Publishing

  private func publishPosition() {
    guard !disposed else { return }
    let ms = milliseconds(player.currentTime())
    if ms >= 0 { emit("position", value: Int(ms)) }
  }

  private func publishDuration() {
    guard !disposed, let item else { return }
    let seconds = item.duration.seconds
    guard seconds.isFinite, seconds > 0 else { return }
    let ms = Int64(seconds * 1000)
    guard ms != lastDurationMs else { return }
    lastDurationMs = ms
    emit("duration", value: Int(ms))
  }

  private func publishVideoSize() {
    guard !disposed, let item else { return }
    // `tracks(withMediaType:)` is deprecated from iOS 16 but still the only
    // synchronous accessor; the async replacement would race the first frame.
    let tracks = item.asset.tracks(withMediaType: .video)
    guard let track = tracks.first else { return }

    // AVPlayerItemVideoOutput hands back the DECODED buffer, so any rotation in
    // the track's preferredTransform is NOT applied to the pixels. Flutter's
    // Texture therefore shows the picture sideways unless the Dart side rotates
    // it, which is exactly what `rotationCorrection` is for (Android reports the
    // same thing for its non-rotating texture backend).
    let degrees = trackRotation(track)
    let natural = track.naturalSize
    guard natural.width > 0, natural.height > 0 else { return }
    let quarter = degrees == 90 || degrees == 270
    let size = quarter
      ? CGSize(width: natural.height, height: natural.width)
      : natural
    guard size != lastVideoSize else { return }
    lastVideoSize = size
    emit("videoSize", extra: [
      "width": Int(size.width.rounded()),
      "height": Int(size.height.rounded()),
      "rotationCorrection": degrees,
      "formatRotation": degrees,
      "handlesCropAndRotation": false,
    ])
  }

  /// Clockwise rotation encoded in a track's preferred transform, normalised to
  /// the four values a RotatedBox can express.
  private func trackRotation(_ track: AVAssetTrack) -> Int {
    let t = track.preferredTransform
    // A pure rotation has a == d and b == -c; anything else (mirroring, scale)
    // is not something a quarter-turn RotatedBox can express.
    let degrees = Int((atan2(t.b, t.a) * 180 / Double.pi).rounded())
    let normalised = ((degrees % 360) + 360) % 360
    return [0, 90, 180, 270].contains(normalised) ? normalised : 0
  }

  private func publishPlaying() {
    guard !disposed else { return }
    let playing = player.rate != 0 && player.error == nil
    if playing != lastPlaying {
      lastPlaying = playing
      emit("playing", value: playing)
    }
    let playWhenReady = player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    if playWhenReady != lastPlayWhenReady {
      lastPlayWhenReady = playWhenReady
      emit("playWhenReady", value: playWhenReady)
    }
  }

  private func emitBuffering(_ buffering: Bool) {
    guard buffering != lastBuffering else { return }
    lastBuffering = buffering
    emit("buffering", value: buffering)
  }

  private func emitError(_ error: Error?) {
    var payload: [String: Any] = [
      "message": error?.localizedDescription ?? "Player error",
    ]
    if let nsError = error as NSError? {
      payload["errorCode"] = nsError.code
      if let status = nsError.userInfo["statusCode"] as? Int {
        payload["httpStatusCode"] = status
      }
    }
    emit("error", value: payload)
  }

  private func emit(_ type: String, value: Any) {
    emit(type, extra: ["value": value])
  }

  private func emit(_ type: String, extra: [String: Any]) {
    guard !disposed, let sink else { return }
    var payload = extra
    payload["playerId"] = playerId
    payload["type"] = type
    sink(payload)
  }

  private func milliseconds(_ time: CMTime) -> Int64 {
    guard time.isValid, !time.isIndefinite, !time.isNegativeInfinity else { return -1 }
    return Int64(CMTimeGetSeconds(time) * 1000)
  }

  // MARK: - Teardown

  func dispose() {
    guard !disposed else { return }
    disposed = true

    if let endObservation {
      NotificationCenter.default.removeObserver(endObservation)
    }
    statusObservation?.invalidate()
    bufferObservation?.invalidate()
    rateObservation?.invalidate()

    displayLink?.invalidate()
    displayLink = nil

    player.pause()
    player.replaceCurrentItem(with: nil)
    item?.remove(videoOutput)

    registry.unregisterTexture(textureId)
    sink = nil
  }
}

/// MethodChannel `fqapp/native_player` + EventChannel `fqapp/native_player/events`.
///
/// Not `public`: both files compile into the Runner target, so internal
/// visibility is enough, and an ObjC protocol conformance on a `public` class
/// would force every member to be `@objc`-exposed for no benefit.
final class NativePlayerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let channelName = "fqapp/native_player"
  private static let eventName = "fqapp/native_player/events"

  private var players: [Int: NativePlayerInstance] = [:]
  private var nextPlayerId = 1
  private var eventSink: FlutterEventSink?
  private var attachedToEngine = false
  private var registry: FlutterTextureRegistry?
  private var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NativePlayerPlugin()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(name: eventName, binaryMessenger: registrar.messenger())
    instance.channel = channel
    instance.registry = registrar.textures()
    events.setStreamHandler(instance)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "create":
      create(args, result: result)

    case "play", "pause", "seek", "setVolume", "setRate":
      guard let player = player(for: args) else { return result(flutterError("unknown player")) }
      switch call.method {
      case "play": player.play()
      case "pause": player.pause()
      case "seek": player.seek(toMilliseconds: int64(args["positionMs"]))
      case "setVolume": player.setVolume(Float(double(args["volume"], fallback: 1)))
      default: player.setRate(Float(double(args["rate"], fallback: 1)))
      }
      result(nil)

    case "dispose":
      guard let id = args["id"] as? Int, let player = players.removeValue(forKey: id) else {
        return result(nil)
      }
      player.dispose()
      result(nil)

    case "setKeepScreenOn":
      // Flutter's video views keep the screen awake through the framework, and
      // UIApplication.isIdleTimerDisabled is process-wide: honouring this would
      // keep the display on after leaving the player.
      result(nil)

    // Listening keeps playing through AVAudioSession, which needs no foreground
    // service on iOS. Report success so the Dart side does not log a failure.
    case "startListenForeground", "stopListenForeground":
      result(nil)

    // Overlay permission is an Android concept. Answering false (instead of
    // throwing) is what makes the Dart side hide the floating-window entry.
    case "canDrawOverlays", "requestOverlayPermission":
      result(false)

    case "startFloating", "showFloating", "updateFloating", "stopFloating", "swapFloatingPlayer":
      result(flutterError("floating window is not available on iOS"))

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func create(_ args: [String: Any], result: @escaping FlutterResult) {
    guard attachedToEngine, let registry, eventSink != nil else {
      return result(flutterError("player host is not attached"))
    }
    guard let raw = args["cdnUrl"] as? String, let url = URL(string: raw) else {
      return result(flutterError("create: missing cdnUrl"))
    }
    guard url.scheme == "http" || url.scheme == "https" else {
      return result(flutterError("create: unsupported scheme \(url.scheme ?? "nil")"))
    }
    let id = nextPlayerId
    nextPlayerId += 1
    let player = NativePlayerInstance(
      playerId: id,
      url: url,
      registry: registry,
      sink: { [weak self] event in self?.eventSink?(event) }
    )
    players[id] = player
    result(["playerId": id])
  }

  private func player(for args: [String: Any]) -> NativePlayerInstance? {
    guard let id = args["id"] as? Int else { return nil }
    return players[id]
  }

  private func int64(_ value: Any?) -> Int64 {
    if let n = value as? Int { return Int64(n) }
    if let n = value as? NSNumber { return n.int64Value }
    if let d = value as? Double { return Int64(d) }
    return 0
  }

  private func double(_ value: Any?, fallback: Double) -> Double {
    if let d = value as? Double { return d }
    if let n = value as? NSNumber { return n.doubleValue }
    return fallback
  }

  private func flutterError(_ message: String) -> FlutterError {
    FlutterError(code: "native_player", message: message, details: nil)
  }

  // MARK: - FlutterStreamHandler

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    attachedToEngine = true
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    attachedToEngine = false
    return nil
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    attachedToEngine = false
    eventSink = nil
    for player in players.values { player.dispose() }
    players.removeAll()
    channel?.setMethodCallHandler(nil)
  }
}
