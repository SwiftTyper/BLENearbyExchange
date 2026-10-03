import AVFoundation
import Foundation
import OSLog

enum SystemSoundPlayer: String {
  case fail = "nfc_scan_failure"
  case success = "nano/AccessScanComplete_Haptic"
  case connected = "nano/MultiwayJoin"

  static func play(_ sound: Self) throws {
    try playSound(at: sound.rawValue)
  }
}

extension SystemSoundPlayer {
  private static func playSound(at fileName: String) throws {
    let fileUrl = URL(fileURLWithPath: "/System/Library/Audio/UISounds/\(fileName).caf")
    var soundId: SystemSoundID = 0
    let status = AudioServicesCreateSystemSoundID(fileUrl as CFURL, &soundId)

    guard status == kAudioServicesNoError else {
      Logger.sound.debug("AudioServicesCreateSystemSoundID failed: \(status)")
      throw Failure.soundIdCreation
    }

    AudioServicesPlaySystemSoundWithCompletion(soundId) {
      AudioServicesDisposeSystemSoundID(soundId)
    }
  }

  enum Failure: Error {
    case soundIdCreation
  }
}

private extension Logger {
  static let sound = Logger(subsystem: "blenearbyexchange", category: "sound")
}
