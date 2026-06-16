import Foundation

actor AudioCaptureCoordinator {
    typealias SampleHandler = @Sendable ([Float], Int32) async -> Void

    private var onSamples: SampleHandler?

    func configure(onSamples: @escaping SampleHandler) {
        self.onSamples = onSamples
    }

    func accept(samples: [Float], sampleRate: Int32) async {
        guard !samples.isEmpty, let onSamples else { return }
        await onSamples(samples, sampleRate)
    }

    func reset() {
        onSamples = nil
    }
}
