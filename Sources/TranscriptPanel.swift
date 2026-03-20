import AppKit
import SwiftUI

/// Floating panel that displays real-time meeting transcription.
/// NSPanel at floating level, does not steal focus.
final class TranscriptPanel: @unchecked Sendable {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<TranscriptPanelView>?
    private var viewModel: TranscriptPanelViewModel?

    var opacity: Double = 0.85

    @MainActor
    func show() {
        guard panel == nil else { return }

        let vm = TranscriptPanelViewModel()
        vm.opacity = opacity
        self.viewModel = vm

        let contentView = TranscriptPanelView(viewModel: vm)
        let hosting = NSHostingView(rootView: contentView)
        self.hostingView = hosting

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 400, height: 300)
        let panelWidth: CGFloat = 360
        let panelHeight: CGFloat = 400
        let panelX = screenFrame.maxX - panelWidth - 20
        let panelY = screenFrame.maxY - panelHeight - 20

        let p = NSPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "Meeting Transcript"
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.contentView = hosting
        p.isOpaque = false
        p.backgroundColor = NSColor.black.withAlphaComponent(opacity)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.orderFront(nil)

        self.panel = p
    }

    @MainActor
    func hide() {
        panel?.close()
        panel = nil
        hostingView = nil
        viewModel = nil
    }

    func appendSegment(_ segment: MeetingSegment) {
        DispatchQueue.main.async {
            self.viewModel?.appendSegment(segment)
        }
    }

    func updateTimer(_ text: String) {
        DispatchQueue.main.async {
            self.viewModel?.timerText = text
        }
    }
}

// MARK: - ViewModel

@MainActor
final class TranscriptPanelViewModel: ObservableObject {
    @Published var segments: [MeetingSegment] = []
    @Published var timerText: String = "00:00"
    @Published var opacity: Double = 0.85

    /// Current partial (non-final) segment being updated.
    private var currentPartialID: String?

    func appendSegment(_ segment: MeetingSegment) {
        if segment.isFinal {
            // Remove any partial with same speaker, add final
            if let partialID = currentPartialID {
                segments.removeAll { $0.id == partialID }
                currentPartialID = nil
            }
            segments.append(segment)
        } else {
            // Update or add partial
            if let partialID = currentPartialID,
               let idx = segments.firstIndex(where: { $0.id == partialID }) {
                segments[idx] = segment
            } else {
                currentPartialID = segment.id
                segments.append(segment)
            }
        }
    }
}

// MARK: - SwiftUI View

struct TranscriptPanelView: View {
    @ObservedObject var viewModel: TranscriptPanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Timer bar
            HStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("Recording")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(viewModel.timerText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.segments, id: \.id) { segment in
                            HStack(alignment: .top, spacing: 8) {
                                Text(formatTimestamp(segment.timestamp))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 40, alignment: .trailing)

                                Text("S\(segment.speakerIndex + 1)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(speakerColor(segment.speakerIndex))

                                Text(segment.text)
                                    .font(.system(.body, design: .default))
                                    .foregroundColor(segment.isFinal ? .primary : .secondary)
                                    .id(segment.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.segments.count) { _, _ in
                    if let last = viewModel.segments.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func speakerColor(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan]
        return colors[index % colors.count]
    }
}
