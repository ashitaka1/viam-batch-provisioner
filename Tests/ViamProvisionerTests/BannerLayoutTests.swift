import SwiftUI
import Testing
@testable import ViamProvisioner

/// The window's minimum size is its content's size at a zero proposal, so a view that
/// grows tall when squeezed narrow pushes the whole window's content off screen.
@MainActor @Test func bannerStaysOneLineTallWhenSqueezed() {
    let message = "127.0.0.1:8235: Could not connect to the server. Reconnecting automatically."
    let squeezed = NSHostingController(rootView: Banner(message: message) {}).sizeThatFits(in: .zero)
    // One line of text with the banner's padding is about 40 pt.
    #expect(squeezed.height < 60)
}
