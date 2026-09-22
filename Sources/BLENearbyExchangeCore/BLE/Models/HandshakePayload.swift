import Foundation

struct HandshakePayload: Codable {
  let publicKey: Data
  let token: Data
}
