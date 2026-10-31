import SwiftUI
import AVKit
import Photos

struct WorksView: View {
    @EnvironmentObject var store: Store
    @State private var playing: WorkItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.works) { w in
                        row(w)
                    }
                    if store.works.isEmpty {
                        Text("还没有拍过东西\n拍完会自动出现在这里")
                            .font(.system(size: 14))
                            .foregroundColor(T.sub)
                            .multilineTextAlignment(.center)
                            .padding(.top, 60)
                    }
                }
                .padding(16)
            }
            .background(T.bg.ignoresSafeArea())
            .navigationTitle("作品")
            .onAppear { store.refreshWorks() }
            .sheet(item: $playing) { w in
                PlaySheet(item: w)
                    .environmentObject(store)
            }
        }
    }

    private func row(_ w: WorkItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(T.accent.opacity(0.12))
                Image(systemName: "play.fill")
                    .font(.system(size: 16))
                    .foregroundColor(T.accent)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(w.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                Text(w.dateText + " · " + w.sizeText)
                    .font(.system(size: 12))
                    .foregroundColor(T.sub)
            }
            Spacer()
            Button {
                playing = w
            } label: {
                Text("查看")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(T.accent)
                    .clipShape(Capsule())
            }
        }
        .card()
        .contextMenu {
            Button(role: .destructive) {
                store.deleteWork(w)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

struct PlaySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let item: WorkItem

    @State private var tip: String?
    @State private var player: AVPlayer

    init(item: WorkItem) {
        self.item = item
        _player = State(initialValue: AVPlayer(url: item.url))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VideoPlayer(player: player)
                    .frame(maxHeight: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }

                HStack(spacing: 10) {
                    Button {
                        PhotoSaver.save(item.url) { ok, msg in
                            tip = ok ? "已存进相册" : (msg.isEmpty ? "保存失败" : msg)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                            Text("存进相册")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(T.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Button {
                        store.deleteWork(item)
                        dismiss()
                    } label: {
                        Text("删除")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(T.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(T.danger.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                if let t = tip {
                    Text(t)
                        .font(.system(size: 12))
                        .foregroundColor(T.sub)
                }
            }
            .padding(16)
            .background(T.bg.ignoresSafeArea())
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

enum PhotoSaver {
    static func save(_ url: URL, done: @escaping (Bool, String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                DispatchQueue.main.async { done(false, "没有相册写入权限，去 设置 里打开") }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, err in
                DispatchQueue.main.async {
                    done(ok, err?.localizedDescription ?? "")
                }
            }
        }
    }
}
