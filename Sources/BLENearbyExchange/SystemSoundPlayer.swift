import Foundation
import AVFoundation

enum SystemSoundPlayer: String {
  case fail = "nfc_scan_failure"
  case success = "nano/AccessScanComplete_Haptic"
  case connected = "nano/MultiwayJoin"
  
  static func play(_ sound: Self) throws {
    try Self.playSound(at: sound.rawValue)
  }
}

extension SystemSoundPlayer {
  private static func playSound(at fileName: String) throws {
    let fileUrl = URL(fileURLWithPath: "/System/Library/Audio/UISounds/\(fileName).caf")
    print(fileUrl.absoluteString, FileManager.default.fileExists(atPath: fileUrl.path))
    var soundId: SystemSoundID = 0
    let status = AudioServicesCreateSystemSoundID(fileUrl as CFURL, &soundId)
    
    guard status == kAudioServicesNoError else {
      NSLog("AudioServicesCreateSystemSoundID failed: %d", status);
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

