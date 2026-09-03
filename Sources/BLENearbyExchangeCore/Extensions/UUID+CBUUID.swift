import CoreBluetooth
import Foundation

extension UUID {
  var cbuuid: CBUUID {
    CBUUID(string: uuidString)
  }
}
