import Dispatch
import Foundation

/// One accepted TCP peer. `id` is a monotonic token so a delayed timer (e.g. the
/// auth-timeout drop) can tell a reused file descriptor apart from the original.
struct ClientConnection {
  let id: UInt64
  let fileDescriptor: Int32
  let readSource: DispatchSourceRead
  var buffer: Data = Data()
  var authenticated: Bool = false
}
