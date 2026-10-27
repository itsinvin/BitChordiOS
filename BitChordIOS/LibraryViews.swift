import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Downloads + local library screens

public struct DownloadsView: View {
    @StateObject private var downloads = DownloadsStore.shared
    @StateObject private var player = PlayerEngine.shared
    public var body: some View {
        List {
            if downloads.manifest.isEmpty && downloads.activeDownloads.isEmpty {
                Section { Text("Nothing downloaded yet. Use Download on any track's context menu.").foregroundStyle(.secondary) }
            }
            if !downloads.activeDownloads.isEmpty {
                Section("Downloading") {
                    ForEach(Array(downloads.activeDownloads), id: \.self) { id in
                        HStack {
                            Text(id).lineLimit(1)
                            Spacer()
                            if let p = downloads.progress[id] { Text("\(Int(p * 100))%").font(.caption).foregroundStyle(.secondary) }
                            Button("Cancel") { downloads.cancel(Track(id: id, title: id)) }
                        }
                    }
                }
            }
            Section("Downloaded") {
                ForEach(downloads.downloadedTracks()) { track in
                    HStack {
                        TrackRow(track: track) { player.playTrack(track) }
                        Spacer()
                        Button(role: .destructive) { downloads.delete(track) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Downloads")
    }
}

public struct DocumentPicker: UIViewControllerRepresentable {
    public var onPick: (URL) -> Void
    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.audio], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }
    public func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    public func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    public final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            for url in urls { onPick(url) }
        }
    }
}

public struct LocalLibraryView: View {
    @StateObject private var local = LocalLibrary.shared
    @State private var showingPicker = false
    @State private var importMessage: String?
    public var body: some View {
        List {
            Section {
                Button("Grant Apple Music library access") { local.requestAuthorization() }
                Text("Status: \(String(describing: local.authorizationStatus))").font(.caption).foregroundStyle(.secondary)
                Button("Import audio files from Files") { showingPicker = true }
                if let msg = importMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
                Picker("Sort", selection: $local.sortOrder) { ForEach(LocalLibrary.SortOrder.allCases, id: \.self) { s in Text(s.rawValue).tag(s) } }
                    .pickerStyle(.segmented)
                    .onChange(of: local.sortOrder) { _, _ in local.applySort() }
            }
            Section("Songs on this device") {
                ForEach(local.songs) { track in TrackRow(track: track) { PlayerEngine.shared.playTrack(track) } }
            }
            Section("Imported files") {
                ForEach(local.importedFiles) { track in TrackRow(track: track) { PlayerEngine.shared.playTrack(track) } }
            }
            Section("Albums") {
                ForEach(local.albums) { album in NavigationLink(album.title, value: DetailDestination.album(album)) }
            }
            Section("Artists") {
                ForEach(local.artists) { artist in NavigationLink(artist.name, value: DetailDestination.artist(artist)) }
            }
            if local.songs.isEmpty && local.importedFiles.isEmpty {
                Section { Text("No local tracks yet. Grant access above or import files.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Local files")
        .navigationDestination(for: DetailDestination.self) { dest in DetailView(destination: dest) }
        .sheet(isPresented: $showingPicker) {
            DocumentPicker { url in
                importMessage = local.importFile(url) ? "Imported \(url.lastPathComponent)." : "Could not import \(url.lastPathComponent)."
            }
        }
        .task { local.refresh() }
    }
}
