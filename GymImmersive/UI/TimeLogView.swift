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
                Button {
                    exportText = controller.timeLogText
                    showExporter = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(controller.timeLog.isEmpty)
                .accessibilityHint("Saves the time log as a text file")
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
