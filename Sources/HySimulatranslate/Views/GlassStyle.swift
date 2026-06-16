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
    @Binding var isFullScreen: Bool
    private let trafficLightCenterInset: CGFloat = 21

    func makeCoordinator() -> Coordinator {
        Coordinator(isFullScreen: $isFullScreen)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(from: view, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(from: nsView, context: context)
        }
    }

    private func configureWindow(from view: NSView, context: Context) {
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        context.coordinator.attach(to: window)
        context.coordinator.updateFullScreenState(from: window)
        alignTrafficLightButtons(in: window)
    }

    private func alignTrafficLightButtons(in window: NSWindow) {
        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }

        guard let container = buttons.first?.superview else { return }

        guard let redButton = buttons.min(by: { $0.frame.midX < $1.frame.midX }) else { return }
        let horizontalShift = trafficLightCenterInset - redButton.frame.midX

        for button in buttons {
            var frame = button.frame
            frame.origin.x += horizontalShift
            if container.isFlipped {
                frame.origin.y = max(0, trafficLightCenterInset - frame.height / 2)
            } else {
                frame.origin.y = max(0, container.bounds.height - trafficLightCenterInset - frame.height / 2)
            }
            button.frame = frame
        }
    }

    final class Coordinator {
        private var isFullScreen: Binding<Bool>
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
        }

        deinit {
            removeObservers()
        }

        func attach(to window: NSWindow) {
            guard observedWindow !== window else { return }
            removeObservers()
            observedWindow = window

            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    self?.updateFullScreenState(from: window)
                },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    self?.updateFullScreenState(from: window)
                }
            ]
        }

        func updateFullScreenState(from window: NSWindow) {
            let newValue = window.styleMask.contains(.fullScreen)
            if isFullScreen.wrappedValue != newValue {
                isFullScreen.wrappedValue = newValue
            }
        }

        private func removeObservers() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
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
                .stroke(.white.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }
}
