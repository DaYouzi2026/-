import SwiftUI

@main
struct TidanciApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.light)
        }
    }
}

struct RootView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("台本", systemImage: "text.alignleft") }
                .tag(0)
            WorksView()
                .tabItem { Label("作品", systemImage: "square.stack") }
                .tag(1)
        }
        .tint(T.accent)
    }
}

// MARK: - 首页

struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var editing: Script?
    @State private var running: Script?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.scripts) { s in
                            row(s)
                        }
                        if store.scripts.isEmpty {
                            Text("还没有台本，点右下角新建一个")
                                .font(.system(size: 14))
                                .foregroundColor(T.sub)
                                .padding(.top, 60)
                        }
                    }
                    .padding(16)
                }
                .background(T.bg.ignoresSafeArea())

                Button {
                    editing = Script(title: "", content: "")
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(T.accent)
                        .clipShape(Circle())
                        .shadow(color: T.accent.opacity(0.35), radius: 12, y: 6)
                }
                .padding(20)
            }
            .navigationTitle("提词大师")
            .sheet(item: $editing) { s in
                ScriptEditor(script: s) { store.upsert($0) }
            }
            .fullScreenCover(item: $running) { s in
                PrompterView(script: s)
                    .environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private func row(_ s: Script) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(s.displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(T.ink)
                Spacer()
                Text("\(s.content.count) 字")
                    .font(.system(size: 12))
                    .foregroundColor(T.sub)
            }
            Text(s.preview)
                .font(.system(size: 13))
                .foregroundColor(T.sub)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    running = s
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "video.fill")
                        Text("开拍")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(T.accent)
                    .clipShape(Capsule())
                }
                Button {
                    editing = s
                } label: {
                    Text("编辑")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(T.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(T.bg)
                        .clipShape(Capsule())
                }
                Spacer()
            }
        }
        .card()
        .contextMenu {
            Button(role: .destructive) {
                store.delete(s)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

// MARK: - 台本编辑

struct ScriptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var script: Script
    private let onSave: (Script) -> Void

    init(script: Script, onSave: @escaping (Script) -> Void) {
        _script = State(initialValue: script)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("标题", text: $script.title)
                    .font(.system(size: 16))
                    .padding(12)
                    .background(T.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                TextEditor(text: $script.content)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(T.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(16)
            .background(T.bg.ignoresSafeArea())
            .navigationTitle("编辑台本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(script)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
