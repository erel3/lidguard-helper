import AppKit
import SwiftUI
import SkyLightWindow

final class LockScreenManager {
  private var window: NSWindow?
  private var hasDelegated = false
  private var viewModel = LockScreenViewModel()
  private(set) var isShowing = false

  private static let windowSize = NSSize(width: 400, height: 200)

  func show(contactName: String, contactPhone: String, message: String) {
    viewModel.message = message
    viewModel.contactInfo = [contactName, contactPhone]
      .filter { !$0.isEmpty }.joined(separator: " \u{2014} ")
    let win = ensureWindow()
    win.orderFrontRegardless()
    isShowing = true
  }

  func hide() {
    window?.orderOut(nil)
    isShowing = false
  }

  private func ensureWindow() -> NSWindow {
    if let window {
      refreshPosition(window: window)
      return window
    }

    let newWindow = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.windowSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    newWindow.isOpaque = false
    newWindow.backgroundColor = .clear
    newWindow.hasShadow = false
    newWindow.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    newWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    newWindow.ignoresMouseEvents = true

    let view = LockScreenMessageView(viewModel: viewModel)
      .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: Self.windowSize)
    newWindow.contentView = hosting

    refreshPosition(window: newWindow)

    if !hasDelegated {
      SkyLightOperator.shared.delegateWindow(newWindow)
      hasDelegated = true
    }

    window = newWindow
    return newWindow
  }

  private func refreshPosition(window: NSWindow) {
    guard let screen = NSScreen.screens.first else { return }
    let screenFrame = screen.frame
    let size = Self.windowSize
    let originX = screenFrame.origin.x + (screenFrame.width - size.width) / 2
    let originY = screenFrame.origin.y + (screenFrame.height - size.height) / 2
    window.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
  }
}

// MARK: - ViewModel

class LockScreenViewModel: ObservableObject {
  @Published var message: String = "STOLEN DEVICE"
  @Published var contactInfo: String = ""
}

// MARK: - View

struct LockScreenMessageView: View {
  @ObservedObject var viewModel: LockScreenViewModel

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 48))
        .foregroundColor(.red)

      Text(viewModel.message)
        .font(.system(size: 24, weight: .bold))
        .foregroundColor(.white)
        .multilineTextAlignment(.center)

      Text(viewModel.contactInfo)
        .font(.system(size: 16))
        .foregroundColor(.white.opacity(0.8))
    }
    .padding(32)
    .background(.ultraThinMaterial)
    .cornerRadius(20)
  }
}
