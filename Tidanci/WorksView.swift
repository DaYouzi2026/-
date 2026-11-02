import SwiftUI
import AVKit
import Photos

struct WorksView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var thumbs = ThumbStore.shared

    @State private var playing: WorkItem?
    @State private var tip: String?

    private var totalText: String {
        let total = store.works.reduce(Int64(0)) { $0 + $1.size }
        let mb = Double(total) / 1048576.0
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                T.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if store.works.isEmpty {
                                EmptyState(icon: "video.slash",
                                           title: "还没有拍过东西",
                                           sub: "回到台本页，选一篇点「开拍」，录完就会存到这里")
                            } else {
                                grid
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 40)
                    }
                }

                if let t = tip {
                    Toast(text: t).padding(.top, 6)
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                store.refreshWorks()
                ThumbStore.shared.reset()
            }
            .sheet(item: $playing) { w in
                PlaySheet(item: w)
                    .environmentObject(store)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("作品")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
            Text(store.works.isEmpty ? "拍完自动出现在这里" : "\(store.works.count) 个 · \(totalText)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .background(
            T.grad
                .ignoresSafeArea(edges: .top)
        )
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)],
                  spacing: 14) {
            ForEach(store.works) { w in
                tile(w)
                    .onAppear { thumbs.load(w.url) }
            }
        }
    }

    private func tile(_ w: WorkItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                playing = w
            } label: {
                ZStack {
                    thumbImage(w)

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white.opacity(0.94))
                        .shadow(color: Color.black.opacity(0.35), radius: 6)

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(timeText(w))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .padding(7)
                    }
                }
                .frame(height: 152)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .pressable()

            Text(w.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(T.ink2)
                .lineLimit(1)
            Text(w.dateText + " · " + w.sizeText)
                .font(.system(size: 10))
                .foregroundColor(T.sub)
                .lineLimit(1)
        }
        .contextMenu {
            Button { playing = w } label: { Label("播放", systemImage: "play") }
            Button { saveToAlbum(w) } label: { Label("存进相册", systemImage: "square.and.arrow.down") }
            Button(role: .destructive) { remove(w) } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func thumbImage(_ w: WorkItem) -> some View {
        Color.clear
            .overlay(
                Group {
                    if let img = thumbs.images[w.url] {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            T.surface2
                            Image(systemName: "video")
                                .font(.system(size: 20))
                                .foregroundColor(T.sub.opacity(0.5))
                        }
                    }
                }
            )
            .clipped()
    }

    private func timeText(_ w: WorkItem) -> String {
        if let d = thumbs.durations[w.url], d > 0 { return d.mmss }
        return "--:--"
    }

    private func saveToAlbum(_ w: WorkItem) {
        PhotoSaver.save(w.url) { ok, msg in
            show(ok ? "已存进相册" : (msg.isEmpty ? "保存失败" : msg))
        }
    }

    private func remove(_ w: WorkItem) {
        store.deleteWork(w)
        thumbs.forget(w.url)
        show("已删除")
    }

    private func show(_ t: String) {
        tip = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { tip = nil }
    }
}

// MARK: - 播放

struct PlaySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    let item: WorkItem

    @State private var player: AVPlayer
    @State private var tip: String?
    @State private var confirmDelete = false
    @State private var editing = false

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
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }

                HStack(spacing: 9) {
                    Button {
                        player.pause()
                        editing = true
                    } label: {
                        actionLabel("编辑", "wand.and.stars", T.accent2)
                    }
                    .pressable()

                    Button {
                        PhotoSaver.save(item.url) { ok, msg in
                            tip = ok ? "已存进相册" : (msg.isEmpty ? "保存失败" : msg)
                        }
                    } label: {
                        actionLabel("存相册", "square.and.arrow.down", T.accent)
                    }
                    .pressable()

                    ShareLink(item: item.url) {
                        actionLabel("分享", "square.and.arrow.up", T.ink2)
                    }
                    .pressable()

                    Button {
                        confirmDelete = true
                    } label: {
                        actionLabel("删除", "trash", T.danger)
                    }
                    .pressable()
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
            .confirmationDialog("删除这个视频？删了就找不回来了", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    player.pause()
                    store.deleteWork(item)
                    ThumbStore.shared.forget(item.url)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $editing) {
                EditorView(item: item)
                    .environmentObject(store)
            }
        }
    }

    private func actionLabel(_ title: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(T.line, lineWidth: 1)
        )
    }
}

// MARK: - 存相册

enum PhotoSaver {
    static func save(_ url: URL, done: @escaping (Bool, String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                DispatchQueue.main.async { done(false, "没有相册写入权限，去设置里打开") }
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
