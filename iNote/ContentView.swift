//
//  ContentView.swift
//  iNote
//
//  Created by jananzhu on 10/4/25.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = NotesViewModel()
    @State private var showDirectoryPicker = false
    @State private var hasPresentedInitialPicker = false
    @State private var isCardFading = false

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            content
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showDirectoryPicker) {
            DirectoryPicker { url in
                showDirectoryPicker = false
                viewModel.setDirectory(url)
            } onCancel: {
                showDirectoryPicker = false
            }
        }
        .task {
            guard !hasPresentedInitialPicker else { return }
            hasPresentedInitialPicker = true
            if viewModel.needsDirectorySelection {
                showDirectoryPicker = true
            }
        }
        .onChange(of: viewModel.currentNote?.fileName) { _ in
            withAnimation(.easeInOut(duration: 0.28)) {
                isCardFading = false
            }
        }
        .onChange(of: viewModel.errorMessage) { _ in
            withAnimation(.easeInOut(duration: 0.28)) {
                isCardFading = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.needsDirectorySelection {
            VStack(spacing: 16) {
                Text("Pick a folder full of .txt notes to get started.")
                    .multilineTextAlignment(.center)
                    .font(.title3)

                Button {
                    showDirectoryPicker = true
                } label: {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        } else if viewModel.currentNote == nil && viewModel.isLoading {
            ProgressView("Loading note…")
                .progressViewStyle(.circular)
        } else if let note = viewModel.currentNote {
            VStack(spacing: 20) {
                Spacer()

                VStack(alignment: .leading, spacing: 16) {
                    Text(note.fileName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(note.text)
                        .font(.title3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if note.isTruncated {
                        Text("Displayed note trimmed for quick viewing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, alignment: .center)

                Spacer()

                if viewModel.noteCount > 0 {
                    Text("Tap anywhere to shuffle — \(viewModel.noteCount) note\(viewModel.noteCount == 1 ? "" : "s").")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isCardFading ? 0 : 1)
            .animation(.easeInOut(duration: 0.28), value: isCardFading)
            .contentShape(Rectangle())
            .onTapGesture {
                shuffleWithFade()
            }
        } else if let error = viewModel.errorMessage {
            VStack(spacing: 16) {
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button {
                    if viewModel.hasActiveDirectory {
                        shuffleWithFade()
                    } else {
                        showDirectoryPicker = true
                    }
                } label: {
                    Label(viewModel.hasActiveDirectory ? "Try Again" : "Choose Folder", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            EmptyView()
        }
    }

    private func shuffleWithFade() {
        guard !viewModel.isLoading else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            isCardFading = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            viewModel.shuffle()
        }
    }
}

// MARK: - View Model

final class NotesViewModel: ObservableObject {
    @Published private(set) var currentNote: DisplayNote?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var noteCount = 0
    @Published private(set) var needsDirectorySelection = true

    var hasActiveDirectory: Bool { directoryURL != nil }

    private var directoryURL: URL?
    private let loaderQueue = DispatchQueue(label: "notes.random.loader", qos: .userInitiated)

    func setDirectory(_ url: URL) {
        guard url.hasDirectoryPath else {
            errorMessage = "Please pick a folder, not a file."
            needsDirectorySelection = true
            return
        }

        directoryURL = url
        needsDirectorySelection = false
        errorMessage = nil
        shuffle()
    }

    func shuffle() {
        guard !isLoading else { return }
        guard let directoryURL else {
            needsDirectorySelection = true
            return
        }
        loadRandomNote(from: directoryURL)
    }

    private func loadRandomNote(from directory: URL) {
        isLoading = true
        errorMessage = nil

        let selectedDirectory = directory

        loaderQueue.async { [weak self] in
            guard let self else { return }

            let accessing = selectedDirectory.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    selectedDirectory.stopAccessingSecurityScopedResource()
                }
            }

            let result = Self.fetchRandomNote(in: selectedDirectory)

            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let payload):
                    self.noteCount = payload.availableCount
                    self.currentNote = payload.note
                    self.errorMessage = nil
                case .failure(let error):
                    self.noteCount = 0
                    self.currentNote = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private static func fetchRandomNote(in directory: URL) -> Result<NotePayload, NoteError> {
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let textFiles = urls.filter { $0.pathExtension.lowercased() == "txt" }

            guard let randomURL = textFiles.randomElement() else {
                throw NoteError.noTextFiles
            }

            let data = try Data(contentsOf: randomURL)
            guard let rawText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                throw NoteError.unreadableFile(randomURL.lastPathComponent)
            }

            let note = DisplayNote.make(from: randomURL, rawText: rawText)
            return .success(NotePayload(note: note, availableCount: textFiles.count))
        } catch let error as NoteError {
            return .failure(error)
        } catch {
            return .failure(.generic(error.localizedDescription))
        }
    }

}

// MARK: - Helpers

struct DisplayNote {
    let fileName: String
    let text: String
    let isTruncated: Bool

    static func make(from url: URL, rawText: String) -> DisplayNote {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLines = 25
        let maxCharacters = 800

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        let limitedLines = Array(lines.prefix(maxLines))
        let exceededLineLimit = lines.count > maxLines

        var candidate = limitedLines.joined(separator: "\n")
        var exceededCharacterLimit = candidate.count > maxCharacters

        if exceededCharacterLimit {
            let index = candidate.index(candidate.startIndex, offsetBy: maxCharacters)
            candidate = String(candidate[..<index])
        }

        var text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        var truncated = exceededLineLimit || exceededCharacterLimit

        if truncated && !text.hasSuffix("…") {
            text += "…"
        }

        return DisplayNote(
            fileName: url.deletingPathExtension().lastPathComponent,
            text: text,
            isTruncated: truncated
        )
    }
}

private struct NotePayload {
    let note: DisplayNote
    let availableCount: Int
}

enum NoteError: LocalizedError {
    case noTextFiles
    case unreadableFile(String)
    case generic(String)

    var errorDescription: String? {
        switch self {
        case .noTextFiles:
            return "No .txt files found in that folder."
        case .unreadableFile(let name):
            return "Could not read \(name). Ensure it is UTF-8 encoded."
        case .generic(let message):
            return message
        }
    }
}

// MARK: - Directory Picker

struct DirectoryPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DirectoryPicker

        init(_ parent: DirectoryPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

#Preview {
    ContentView()
}
