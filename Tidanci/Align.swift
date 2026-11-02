import Foundation
import Combine

// MARK: - 拼音

/// 用系统自带的 CFStringTransform 取拼音，不需要外部数据表。
enum Py {
    private static var cache: [Character: [String]] = [:]

    static func syllables(_ ch: Character) -> [String] {
        if let c = cache[ch] { return c }
        let s = String(ch)
        let isHan = s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        guard isHan else {
            cache[ch] = []
            return []
        }
        let m = NSMutableString(string: s)
        CFStringTransform(m as CFMutableString, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m as CFMutableString, nil, kCFStringTransformStripDiacritics, false)
        let t = (m as String).lowercased()
        let parts = t.split(whereSeparator: { $0 == " " || $0 == "'" }).map(String.init)
        cache[ch] = parts
        return parts
    }

    private static let initials: [String] = [
        "zh", "ch", "sh",
        "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h",
        "j", "q", "x", "r", "z", "c", "s", "y", "w"
    ]

    static func split(_ syl: String) -> (String, String) {
        for i in initials where syl.hasPrefix(i) {
            return (i, String(syl.dropFirst(i.count)))
        }
        return ("", syl)
    }

    /// 容易混的声母分组（平翘舌、n/l、f/h、b/p、d/t、g/k）
    static func group(_ ini: String) -> Int {
        switch ini {
        case "zh", "z", "j": return 1
        case "ch", "c", "q": return 2
        case "sh", "s", "x": return 3
        case "n", "l", "r": return 4
        case "f", "h": return 5
        case "b", "p": return 6
        case "d", "t": return 7
        case "g", "k": return 8
        case "": return -1
        default: return -2
        }
    }

    static func stem(_ fin: String) -> String {
        if fin.hasSuffix("ng") { return String(fin.dropLast(2)) }
        if fin.hasSuffix("n") { return String(fin.dropLast()) }
        return fin
    }

    /// 两个无调音节的代价：0 = 完全一样，100 = 毫不相干
    static func sylCost(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let (ia, fa) = split(a)
        let (ib, fb) = split(b)
        let ga = group(ia), gb = group(ib)
        let sameI = ia == ib
        let confI = !sameI && ga == gb && ga > 0
        let sameF = fa == fb
        let nearF = !sameF && stem(fa) == stem(fb)
        if sameF {
            return confI ? 28 : (sameI ? 55 : 62)
        }
        if nearF {
            return confI ? 45 : 72
        }
        if sameI { return 80 }
        return 100
    }
}

// MARK: - 台本预处理

struct PreparedScript {
    let text: String
    /// 只留汉字 / 英数，标点空白全去掉
    let norm: [Character]
    /// norm[i] 在 text 里的 UTF-16 偏移，用来给 AttributedString 划「已读」区间
    let offsets: [Int]
    /// 每个字的全部读音（多音字会有多个）
    let pinyins: [[String]]
    /// 每个自然句在 norm 里的起始下标
    let sentenceStarts: [Int]

    init(text: String) {
        self.text = text
        var n: [Character] = []
        var o: [Int] = []
        var starts: [Int] = []
        var pending = true
        var i16 = 0
        for ch in text {
            if PreparedScript.keep(ch) {
                if pending {
                    starts.append(n.count)
                    pending = false
                }
                n.append(ch)
                o.append(i16)
            } else if PreparedScript.isBreak(ch) {
                pending = true
            }
            i16 += String(ch).utf16.count
        }
        norm = n
        offsets = o
        pinyins = n.map { Py.syllables($0) }
        sentenceStarts = starts
    }

    static func keep(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first else { return false }
        let v = u.value
        if v >= 0x4E00 && v <= 0x9FFF { return true }
        if v >= 0x3400 && v <= 0x4DBF { return true }
        if v >= 0x41 && v <= 0x5A { return true }
        if v >= 0x61 && v <= 0x7A { return true }
        if v >= 0x30 && v <= 0x39 { return true }
        return false
    }

    /// 句读符号，用来断句
    static func isBreak(_ c: Character) -> Bool {
        return "。！？!?；;\n\r，,".contains(c)
    }

    var isEmpty: Bool { norm.isEmpty }
}

// MARK: - 对齐

/// 台本约束下的模糊对齐。
///
/// 三条通道，从强到弱：
/// 1. **句子锚点**：用户跳到下一句时，直接按句首比对，命中就整段跳过去
/// 2. **模糊对齐**：自由起点编辑距离，同音容错，插入漏字只算半价
/// 3. **短探针**：只说了两三个关键词时，在游标附近小范围找
///
/// 关键修改（v1.6）：跳远不再压缩通过门槛。旧逻辑跳超过 35 字时门槛只剩 0.153，
/// 意味着每个字都必须完全同音才能跳，于是「读到下一句但不动」几乎必然发生。
final class Follower {
    private let script: PreparedScript
    private(set) var cursor = 0

    private var stall = 0
    private var creeped = 0
    private var lastSpokenLen = 0
    private var lastMatchAt = Date()
    private(set) var lastScore: Float = 1

    /// 插入 / 漏一个字的代价。旧值 55 太贵，用户自由发挥几句就超预算
    private let GAP = 45

    init(_ s: PreparedScript) {
        script = s
    }

    private func thFor(_ k: Int) -> Float {
        if k >= 16 { return 0.38 }
        if k >= 10 { return 0.44 }
        return 0.52
    }

    func advance(_ spRaw: [Character]) -> Int {
        let n = script.norm.count
        guard n > 0 else { return 0 }
        let sp = spRaw
        let m = sp.count
        guard m >= 2 else { return cursor }
        if cursor >= n - 1 { return cursor }

        let spPy: [[String]] = sp.map { Py.syllables($0) }

        // 通道 3：只说了两三个字，在游标附近小范围找
        if m <= 3, let e = shortProbe(sp, spPy) {
            return commit(e, m)
        }

        guard m >= 4 else { return cursor }

        // 通道 1：跳到句子开头。用户跳读、跳句时主要靠这条
        if let e = sentenceJump(sp, spPy) {
            return commit(e, m)
        }

        // 通道 2：常规模糊对齐
        var win = 120
        if stall >= 6 { win = 240 }
        if stall >= 14 { win = 520 }
        if stall >= 24 { win = 1000 }

        var e = -1
        if m >= 8 {
            let k = min(16, m)
            e = best(sp, spPy, k, cursor, win, thFor(k))
        }
        if e < 0 && m >= 8 {
            e = best(sp, spPy, 8, cursor, min(win, 120), 0.42)
        }
        if e < 0 && m >= 4 {
            e = best(sp, spPy, min(6, m), cursor, 60, 0.26)
        }

        if e >= 0 { return commit(e, m) }

        stall += 1
        // 一直在说但一直没对上：按语速慢慢蠕，别让画面僵死。
        // 每次只走一个字，走多了会把游标带偏，反而更难对上
        if stall >= 10 && creeped < 10 && cursor < n - 3
            && Date().timeIntervalSince(lastMatchAt) > 2.5
            && m > lastSpokenLen {
            cursor += 1
            creeped += 1
            lastMatchAt = Date()
            stall = 6
            lastSpokenLen = m
            return cursor
        }
        lastSpokenLen = m
        return cursor
    }

    /// 统一收口：判断这一跳是否合理
    private func commit(_ e: Int, _ m: Int) -> Int {
        lastSpokenLen = m
        if e == cursor { return cursor }
        let jump = e - cursor
        // 往前跳：随便；往回纠：最多 40 字，别乱翻页
        if jump > 0 || -jump <= 40 {
            cursor = e
            stall = 0
            creeped = 0
            lastMatchAt = Date()
            return cursor
        }
        return cursor
    }

    // MARK: 通道 1 · 句子锚点

    /// 在游标之后 500 字内，找开头最像的这一句，命中就返回它的起始位置。
    /// 只往前找，不会往回跳。
    private func sentenceJump(_ sp: [Character], _ spPy: [[String]]) -> Int? {
        let n = script.norm.count
        let starts = script.sentenceStarts
        guard !starts.isEmpty, sp.count >= 5 else { return nil }

        let probe = min(6, sp.count)
        let qs = sp.count - probe

        var bestI = -1
        var bestScore = 0.0

        for s in starts {
            if s <= cursor + 2 { continue }
            if s - cursor > 500 { break }
            if s + probe > n { continue }

            var hit = 0
            for t in 0..<probe {
                let c = sp[qs + t]
                if c == script.norm[s + t] {
                    hit += 2
                } else if let a = spPy[qs + t].first,
                          let b = script.pinyins[s + t].first,
                          Py.sylCost(a, b) <= 45 {
                    hit += 1
                }
            }
            let score = Double(hit) / Double(probe * 2)
            if score >= 0.70 && score > bestScore {
                bestScore = score
                bestI = s
            }
        }
        return bestI >= 0 ? bestI : nil
    }

    // MARK: 通道 3 · 短探针

    /// 只说了两三个字时，在游标之后 14 字内找完全同音的位置。
    /// 只往前走，避免因为一个常用词把游标拽回去。
    private func shortProbe(_ sp: [Character], _ spPy: [[String]]) -> Int? {
        let n = script.norm.count
        let len = sp.count
        guard len >= 2, cursor + len <= n else { return nil }

        let lo = cursor
        let hi = min(n - len, cursor + 14)
        if hi < lo { return nil }

        var i = lo
        while i <= hi {
            var ok = true
            for t in 0..<len {
                let c = sp[t]
                let d = script.norm[i + t]
                if c == d { continue }
                guard let a = spPy[t].first,
                      let b = script.pinyins[i + t].first,
                      Py.sylCost(a, b) <= 28 else {
                    ok = false
                    break
                }
            }
            if ok { return i + len }
            i += 1
        }
        return nil
    }

    // MARK: 通道 2 · 自由起点编辑距离

    private func best(_ sp: [Character],
                      _ spPy: [[String]],
                      _ k: Int,
                      _ after: Int,
                      _ win: Int,
                      _ th: Float) -> Int {
        let n = script.norm.count
        let qs = max(0, sp.count - k)
        let lo = max(0, after - k - 4)
        let hi = min(n, after + win)
        if hi - lo < k { return -1 }

        let sn = script.norm
        let spy = script.pinyins

        var prevRow = [Int](repeating: 0, count: k + 1)
        for j in 0...k { prevRow[j] = j * GAP }

        var bestI = -1
        var bestRank = Float.greatestFiniteMagnitude

        var i = lo
        while i < hi {
            var row: [Int]
            if i == lo {
                row = prevRow
            } else {
                row = [Int](repeating: 0, count: k + 1)
                row[0] = 0                      // 起点自由
                let sch = sn[i - 1]
                let sps = spy[i - 1]
                var j = 1
                while j <= k {
                    let sIdx = qs + j - 1
                    var c = 100
                    if sch == sp[sIdx] {
                        c = 0
                    } else if sps.isEmpty || spPy[sIdx].isEmpty {
                        c = 60
                    } else {
                        var m2 = 100
                        for a in sps {
                            for b in spPy[sIdx] {
                                let v = Py.sylCost(a, b)
                                if v < m2 { m2 = v }
                            }
                        }
                        c = m2
                    }
                    let del = prevRow[j] + GAP
                    let ins = row[j - 1] + GAP
                    let sub = prevRow[j - 1] + c
                    var v = del < ins ? del : ins
                    if sub < v { v = sub }
                    row[j] = v
                    j += 1
                }
                prevRow = row
            }

            if i != after {
                let raw = Float(row[k]) / (100.0 * Float(k))
                let jump = i - after
                // 远处的候选只做轻度降权，不再是「几乎不可能通过」
                let limit: Float
                if jump > 0 {
                    limit = jump <= 10 ? th : (jump <= 35 ? th * 0.85 : th * 0.70)
                } else {
                    limit = th * 0.45
                }
                if raw <= limit {
                    var rank = raw
                    if jump > 0 { rank += min(0.10, 0.0009 * Float(jump)) }
                    if rank < bestRank {
                        bestRank = rank
                        bestI = i
                    }
                }
            }
            i += 1
        }
        if bestI >= 0 { lastScore = bestRank }
        return bestI
    }
}

// MARK: - 给界面用的引擎

final class PrompterEngine: ObservableObject {
    @Published private(set) var cursor = 0
    @Published private(set) var prepared: PreparedScript
    @Published private(set) var lastStep = 0

    private var follower: Follower

    init(text: String = "") {
        let p = PreparedScript(text: text)
        prepared = p
        follower = Follower(p)
    }

    func reset(_ text: String) {
        let p = PreparedScript(text: text)
        prepared = p
        follower = Follower(p)
        cursor = 0
        lastStep = 0
    }

    /// 送入识别文本（可以带标点、空格，这里自己洗）
    func feed(_ spoken: String) {
        let chars = Array(spoken).filter { PreparedScript.keep($0) }
        let c = follower.advance(chars)
        if c != cursor {
            lastStep = c - cursor
            cursor = c
        }
    }

    /// 「已读」部分在原文里的结束位置（UTF-16）
    var readEnd: Int {
        let n = prepared.offsets.count
        if cursor <= 0 { return 0 }
        if cursor >= n { return prepared.text.utf16.count }
        return prepared.offsets[cursor]
    }

    var percent: Int {
        let n = prepared.norm.count
        if n == 0 { return 0 }
        return min(100, cursor * 100 / n)
    }

    /// 游标之后的一小段，状态条上提示「现在在这儿」
    var upcoming: String {
        let n = prepared.norm.count
        guard cursor < n else { return "" }
        let end = min(n, cursor + 12)
        return String(prepared.norm[cursor..<end])
    }

    var atEnd: Bool {
        cursor >= prepared.norm.count - 1
    }
}
