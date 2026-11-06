import SwiftUI
import UniformTypeIdentifiers

/// The last session's time log on the Start window: the newest lines and a Save button.
struct TimeLogView: View {
    var controller: SessionController
    @State private var showExporter = false
    @State private var exportText = ""
    @State private var saveNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Time log", systemImage: "clock")
                    .font(.headline)
                Text("\(controller.timeLog.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let file = controller.timeLogURL?.lastPathComponent {
                Text("Saved automatically on this device as \(file).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                // Choose a folder (Files, iCloud Drive, a connected drive…) and save a copy there.
                Button {
                    // The file on disk is the complete log; the in-memory list keeps only the newest lines.
                    exportText = controller.timeLogURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                        ?? controller.timeLogText
                    showExporter = true
                } label: {
                    Label("Save log", systemImage: "square.and.arrow.down")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.timeLog.isEmpty)
                .accessibilityHint("Saves a copy of the time log as a text file in a folder you choose")
                // Or send it: AirDrop, Mail, Messages, Notes, Files…
                if let url = controller.timeLogURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Sends the time log file with AirDrop, Mail, Files and more")
                }
            }
            if let saveNotice {
                Text(saveNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(controller.timeLog.suffix(8)) { entry in
                        Text(entry.line)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .padding(20)
        .frame(width: 640)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .fileExporter(isPresented: $showExporter, document: LogFile(text: exportText),
                      contentType: .plainText,
                      defaultFilename: "GymImmersive_\(controller.summary.sessionID)_timelog") { result in
            switch result {
            case .success:
                saveNotice = "Saved."
            case .failure(let error):
                let cancelled = (error as? CocoaError)?.code == .userCancelled
                if !cancelled { saveNotice = "Could not save: \(error.localizedDescription)" }
            }
        }
    }
}

/// Plain-text document for `fileExporter`.
struct LogFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Live time log in the gym, next to the coach: the newest timestamped lines, updated as
/// events happen. The full log is in the session's `_timelog.txt` and the Save button on the
/// Start window.
struct LiveTimeLogPanel: View {
    var controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Time log", systemImage: "clock")
                    .font(.headline)
                Spacer()
                Text("\(controller.timeLog.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(controller.timeLog.suffix(10)) { entry in
                    Text(entry.line)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 560)
        .glassBackgroundEffect()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Time log, \(controller.timeLog.count) entries")
    }
}
