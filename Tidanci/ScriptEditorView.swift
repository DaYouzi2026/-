import SwiftUI
import UIKit

struct ScriptEditorView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var content: String
    @FocusState private var focused: Bool

    private let id: UUID

    init(script: Script) {
        id = script.id
        _title = State(initialValue: script.title)
        _content = State(initialValue: script.content)
    }

    private var chars: Int {
        content.filter { !$0.isWhitespace && !$0.isNewline }.count
    }

    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                titleField
                editor
                tools
            }
            .padding(16)
            .background(T.bg.ignoresSafeArea())
            .navigationTitle(title.isEmpty ? "新台本" : "编辑台本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
    }

    private var titleField: some View {
        TextField("给这段稿子起个名字", text: $title)
            .font(.system(size: 16, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(T.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(T.line, lineWidth: 1)
            )
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $content)
                .font(.system(size: 16))
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(10)

            if content.isEmpty {
                Text("把稿子粘在这里。\n\n句号、问号后面回车换行，提词时一行一句话最好读。")
                    .font(.system(size: 15))
                    .foregroundColor(T.sub.opacity(0.55))
                    .lineSpacing(4)
                    .padding(.horizontal, 15)
                    .padding(.top, 18)
                    .allowsHitTesting(false)
            }
        }
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(T.line, lineWidth: 1)
        )
    }

    private var tools: some View {
        HStack(spacing: 8) {
            tool("粘贴", "doc.on.clipboard") { paste() }
            tool("一行一句", "text.append") { splitSentences() }
            tool("清空", "trash") { content = "" }

            Spacer(minLength: 4)

            Text("\(chars) 字 · \(Estimate.text(chars))")
                .font(.system(size: 12))
                .foregroundColor(T.sub)
        }
    }

    private func tool(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(T.ink2)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(T.surface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(T.line, lineWidth: 1))
        }
        .pressable()
    }

    private func paste() {
        let raw = UIPasteboard.general.string ?? ""
        guard !raw.isEmpty else { return }
        if content.isEmpty {
            content = raw
        } else {
            content += "\n" + raw
        }
        if title.isEmpty {
            let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
            title = String(oneLine.prefix(16))
        }
    }

    /// 把一段连续的文字按句末标点拆成一行一句
    private func splitSentences() {
        var out = ""
        for ch in content {
            out.append(ch)
            if ch == "。" || ch == "！" || ch == "？" || ch == "!" || ch == "?" {
                out.append("\n")
            }
        }
        while out.contains("\n\n") {
            out = out.replacingOccurrences(of: "\n\n", with: "\n")
        }
        content = out.trimmingCharacters(in: .newlines)
    }

    private func save() {
        store.upsert(Script(id: id, title: title, content: content))
        dismiss()
    }
}
