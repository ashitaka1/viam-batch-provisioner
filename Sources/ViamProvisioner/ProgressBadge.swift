import ProvisionerKit
import SwiftUI

extension ProgressLine.Tone {
    var color: Color {
        switch self {
        case .waiting: .secondary
        case .active: .blue
        case .installed: .green
        case .failed: .red
        }
    }
}

/// A machine's progress: a dot in its tone, then the step it is at.
struct ProgressBadge: View {
    let line: ProgressLine

    var body: some View {
        Label {
            Text(line.text).help(line.text)
        } icon: {
            Image(systemName: "circle.fill").foregroundStyle(line.tone.color).imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
    }
}
