import SwiftUI
import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case dark = "Dark"
    case light = "Light"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .dark: return .darkAqua
        case .light: return .aqua
        }
    }
}

struct GlassWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(from: nsView)
        }
    }

    private func configureWindow(from view: NSView) {
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        alignTrafficLightButtons(in: window)
    }

    private func alignTrafficLightButtons(in window: NSWindow) {
        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }

        guard let container = buttons.first?.superview else { return }

        let leftInset: CGFloat = 16
        let topInset: CGFloat = 16
        let currentLeading = buttons.map(\.frame.minX).min() ?? leftInset
        let horizontalShift = leftInset - currentLeading

        for button in buttons {
            var frame = button.frame
            frame.origin.x += horizontalShift
            if container.isFlipped {
                frame.origin.y = topInset
            } else {
                frame.origin.y = max(0, container.bounds.height - frame.height - topInset)
            }
            button.frame = frame
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 14, material: Material = .regularMaterial) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(material)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
    }
}
