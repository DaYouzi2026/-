import UIKit
import SwiftUI

/// 字幕样式：字体 / 字号 / 位置。
///
/// 字号和位置都用「相对画面的比例」存，不存像素值——
/// 同一条样式用在 1080P 和 4K 上，看起来大小位置一致，不会因为换了画质就变样。
struct SubtitleStyle: Codable, Equatable {
    /// 字体代号，见 `all`
    var fontKey: String = "system"
    /// 字号占画面宽度的比例：0.028 ~ 0.10
    var sizeRatio: Double = 0.050
    /// 字幕底边离画面底边的比例：0.02（贴底）~ 0.80（接近顶部）
    var bottomRatio: Double = 0.07

    struct Option: Identifiable {
        let id: String
        let title: String
        /// 依次尝试的字体名，第一个装得上就用第一个
        let faces: [String]

        var available: Bool {
            if faces.isEmpty { return true }
            return faces.contains { UIFont(name: $0, size: 12) != nil }
        }
    }

    static let all: [Option] = [
        Option(id: "system", title: "系统", faces: []),
        Option(id: "pingfang", title: "苹方", faces: ["PingFangSC-Semibold", "PingFangSC-Regular"]),
        Option(id: "yuanti", title: "圆体", faces: ["YuantiSC-Bold", "YuantiSC-Regular"]),
        Option(id: "songti", title: "宋体", faces: ["SongtiSC-Bold", "SongtiSC-Regular", "STSong"]),
        Option(id: "kaiti", title: "楷体", faces: ["KaitiSC-Bold", "KaitiSC-Regular", "STKaiti"]),
        Option(id: "heiti", title: "黑体", faces: ["STHeitiSC-Medium", "HeitiSC-Medium"]),
        Option(id: "hannotate", title: "手写", faces: ["HannotateSC-W5", "HannotateSC-W7"])
    ]

    /// 这台设备真正装得上的那几个。系统字体永远在第一位。
    static var usable: [Option] {
        all.filter { $0.available }
    }

    func fontSize(width: CGFloat) -> CGFloat {
        max(10, width * CGFloat(sizeRatio))
    }

    /// 指定磅值取字体，界面上「字体选择」的小样用这个
    func uiFont(size: CGFloat) -> UIFont {
        if let o = Self.all.first(where: { $0.id == fontKey }) {
            for f in o.faces {
                if let u = UIFont(name: f, size: size) { return u }
            }
        }
        return UIFont.systemFont(ofSize: size, weight: .semibold)
    }

    func font(width: CGFloat) -> UIFont {
        uiFont(size: fontSize(width: width))
    }

    // MARK: - 存

    static func decode(_ raw: String) -> SubtitleStyle {
        guard !raw.isEmpty,
              let d = raw.data(using: .utf8),
              let s = try? JSONDecoder().decode(SubtitleStyle.self, from: d) else {
            return SubtitleStyle()
        }
        return s.clamped()
    }

    var encoded: String {
        guard let d = try? JSONEncoder().encode(self) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// 界面里拖出来的值一律夹回来，别让某次异常的旧数据把字号撑到看不见/溢出画面
    func clamped() -> SubtitleStyle {
        var s = self
        s.sizeRatio = min(0.10, max(0.028, s.sizeRatio))
        s.bottomRatio = min(0.80, max(0.02, s.bottomRatio))
        if !SubtitleStyle.usable.contains(where: { $0.id == s.fontKey }) {
            s.fontKey = "system"
        }
        return s
    }

    /// 位置的中文说法，用来在界面上提示现在大概在哪
    var positionName: String {
        if bottomRatio < 0.13 { return "底部" }
        if bottomRatio < 0.32 { return "偏下" }
        if bottomRatio < 0.55 { return "中间" }
        if bottomRatio < 0.70 { return "偏上" }
        return "顶部"
    }
}

/// 样式预览：拿一块和画面同比例的黑底，把字幕按同样的比例画上去。
/// 不用等真渲染就能看出「字号多大、落在哪」，避免每次都导出一遍才知道。
struct SubtitleSample: View {
    let style: SubtitleStyle
    var text: String = "大家好，今天聊三件事"

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                Color.black
                Text(text)
                    .font(Font(style.font(width: g.size.width)))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(style.fontSize(width: g.size.width) * 0.16)
                    .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                    .frame(width: g.size.width * 0.88)
                    .padding(.bottom, g.size.height * CGFloat(style.bottomRatio))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
