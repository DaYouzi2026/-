import SwiftUI
import UIKit

@main
struct TidanciApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.light)
                .tint(T.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("台本", systemImage: "text.alignleft") }
                .tag(0)
            WorksView()
                .tabItem { Label("作品", systemImage: "square.stack") }
                .tag(1)
            SettingsView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(2)
        }
    }
}

// MARK: - 台本列表

struct HomeView: View {
    @EnvironmentObject var store: Store

    @State private var query = ""
    @State private var editing: Script?
    @State private var running: Script?
    @State private var toast: String?

    private var list: [Script] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.scripts }
        return store.scripts.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.content.localizedCaseInsensitiveContains(q)
        }
    }

    private var totalChars: Int { store.scripts.reduce(0) { $0 + $1.charCount } }

    private var totalText: String {
        totalChars >= 10000
            ? String(format: "%.1f 万字", Double(totalChars) / 10000)
            : "\(totalChars) 字"
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                T.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 12) {
                        header
                        if list.isEmpty {
                            EmptyState(icon: "text.badge.plus",
                                       title: query.isEmpty ? "还没有台本" : "没搜到",
                                       sub: query.isEmpty ? "点右下角新建，或用左边的粘贴键导一段现成的稿子"
                                                          : "换个关键词试试")
                        } else {
                            ForEach(list) { s in card(s) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 120)
                }

                fab
            }
            .navigationBarHidden(true)
            .overlay(alignment: .top) {
                if let t = toast {
                    Toast(text: t)
                        .padding(.top, 8)
                        .transition(.opacity)
                }
            }
            .sheet(item: $editing) { s in
                ScriptEditorView(script: s)
                    .environmentObject(store)
            }
            .fullScreenCover(item: $running) { s in
                PrompterView(script: s)
                    .environmentObject(store)
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("台本")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(T.ink)
                Spacer()
                Text("\(store.scripts.count) 篇 · \(totalText)")
                    .font(.system(size: 12))
                    .foregroundColor(T.sub)
            }
            searchBar
        }
        .padding(.top, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(T.sub)
            TextField("搜索台本", text: $query)
                .font(.system(size: 14))
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(T.sub)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(T.line, lineWidth: 1)
        )
    }

    // MARK: 卡片

    private func card(_ s: Script) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(T.tint(s.title.isEmpty ? s.id.uuidString : s.title))
                    .frame(width: 5, height: 40)

                VStack(alignment: .leading, spacing: 5) {
                    Text(s.displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(T.ink)
                        .lineLimit(1)
                    Text(s.preview)
                        .font(.system(size: 13))
                        .foregroundColor(T.sub)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Tag(text: "\(s.charCount) 字")
                Tag(text: s.durationText)
                Spacer(minLength: 4)

                Button {
                    editing = s
                } label: {
                    Text("编辑")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(T.ink2)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(T.surface2)
                        .clipShape(Capsule())
                }
                .pressable()

                Button {
                    running = s
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("开拍")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 8)
                    .background(T.accent)
                    .clipShape(Capsule())
                }
                .pressable()
            }
        }
        .card()
        .contextMenu {
            Button {
                editing = s
            } label: { Label("编辑", systemImage: "pencil") }
            Button {
                duplicate(s)
            } label: { Label("复制一份", systemImage: "doc.on.doc") }
            Button(role: .destructive) {
                store.delete(s)
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    // MARK: 悬浮按钮

    private var fab: some View {
        HStack(spacing: 10) {
            Button {
                pasteNew()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(T.ink2)
                    .frame(width: 52, height: 52)
                    .background(T.surface)
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.10), radius: 12, y: 6)
            }
            .pressable()

            Button {
                editing = Script(title: "", content: "")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 58, height: 58)
                    .background(T.grad)
                    .clipShape(Circle())
                    .shadow(color: T.accent.opacity(0.35), radius: 14, y: 7)
            }
            .pressable()
        }
        .padding(.trailing, 20)
        .padding(.bottom, 26)
    }

    // MARK: 动作

    private func pasteNew() {
        let raw = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            showToast("剪贴板里没有文字")
            return
        }
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
        editing = Script(title: String(oneLine.prefix(16)), content: raw)
    }

    private func duplicate(_ s: Script) {
        store.upsert(Script(title: s.displayTitle + " 副本", content: s.content))
        showToast("已复制一份")
    }

    private func showToast(_ t: String) {
        withAnimation { toast = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { toast = nil }
        }
    }
}
