import SwiftUI
import AVKit

struct RecordingsBrowserView: View {
    @ObservedObject var recorder: VideoRecorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if recorder.recentClips.isEmpty {
                    ContentUnavailableView(
                        "No RAW Log Recordings Yet",
                        systemImage: "film.stack",
                        description: Text("Recorded 10-bit Log .mov clips and companion .gcsv Gyroflow files will appear here and in the iOS Files app.")
                    )
                } else {
                    List {
                        ForEach(recorder.recentClips) { item in
                            Button {
                                recorder.selectedClip = item
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "film.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.orange)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.videoURL.lastPathComponent)
                                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.primary)

                                        HStack(spacing: 8) {
                                            Text(String(format: "%.1f MB", item.fileSizeMB))
                                            Text("•")
                                            Text(String(format: "%.1fs", item.durationSeconds))
                                            if item.gcsvURL != nil {
                                                Text("GYROFLOW .GCSV")
                                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(Color.green.opacity(0.2), in: Capsule())
                                                    .foregroundStyle(.green)
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    ShareLink(item: item.videoURL) {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.orange)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: deleteClips)
                    }
                }
            }
            .navigationTitle("Recorded Clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh") {
                        recorder.refreshStorageAndClips()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                recorder.refreshStorageAndClips()
            }
            .sheet(item: $recorder.selectedClip) { clip in
                NavigationStack {
                    VideoPlayer(player: AVPlayer(url: clip.videoURL))
                        .ignoresSafeArea()
                        .navigationTitle(clip.videoURL.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Close") {
                                    recorder.selectedClip = nil
                                }
                            }
                        }
                }
                .preferredColorScheme(.dark)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func deleteClips(at offsets: IndexSet) {
        let fm = FileManager.default
        for idx in offsets {
            let clip = recorder.recentClips[idx]
            try? fm.removeItem(at: clip.videoURL)
            if let gcsv = clip.gcsvURL {
                try? fm.removeItem(at: gcsv)
            }
        }
        recorder.refreshStorageAndClips()
    }
}
