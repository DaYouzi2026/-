import Foundation
import Combine

// MARK: - 拼音

/// 用系统自带的 CFStringTransform 取拼音，不需要外部数据表。
/// iOS 这套（kCFStringTransformMandarinLatin）比我们自己塞个 77KB 的表省事得多。
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

    /// 容易混的声母分组，同组按「打折」处理（平翘舌、n/l、f/h、b/p、d/t、g/k）
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

    /// 去掉前后鼻音尾巴，用于「不完全一样但很接近」的判断
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

    init(text: String) {
        self.text = text
        var n: [Character] = []
        var o: [Int] = []
        var i16 = 0
        for ch in text {
            if PreparedScript.keep(ch) {
                n.append(ch)
                o.append(i16)
            }
            i16 += String(ch).utf16.count
        }
        norm = n
        offsets = o
        pinyins = n.map { Py.syllables($0) }
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

    var isEmpty: Bool { norm.isEmpty }
}

// MARK: - 对齐

/// 台本约束下的模糊对齐。
///
/// 和安卓版同一套思路：把识别结果当成「可能有错的读音串」，在游标附近的台本上做
/// 自由起点编辑距离，插入 / 漏字 / 同音字都只算半个字的代价。
/// 所以「读完了画面不动」这种硬卡死不会被一个字写错触发。
final class Follower {
    private let script: PreparedScript
    private(set) var cursor = 0

    private var stall = 0
    private var creeped = 0
    private var lastSpokenLen = 0
    private var lastMatchAt = Date()
    private(set) var lastScore: Float = 1

    private let GAP = 55

    init(_ s: PreparedScript) {
        script = s
    }

    private func thFor(_ k: Int) -> Float {
        if k >= 16 { return 0.34 }
        if k >= 10 { return 0.40 }
        return 0.46
    }

    func advance(_ spRaw: [Character]) -> Int {
        let n = script.norm.count
        guard n > 0 else { return 0 }
        let sp = spRaw
        let m = sp.count
        guard m >= 3 else { return cursor }
        if cursor >= n - 1 { return cursor }

        var win = 96
        if stall >= 6 { win = 200 }
        if stall >= 14 { win = 480 }
        if stall >= 24 { win = 1200 }

        // 发音串只算一次，DP 里反复用
        let spPy: [[String]] = sp.map { Py.syllables($0) }

        var e = -1
        if m >= 8 {
            let k = min(16, m)
            e = best(sp, spPy, k, cursor, win, thFor(k))
        }
        if e < 0 && m >= 8 && stall >= 2 {
            e = best(sp, spPy, 8, cursor, min(win, 90), 0.40)
        }
        if e < 0 && m >= 4 {
            e = best(sp, spPy, min(6, m), cursor, 24, 0.22)
        }

        if e >= 0 && e != cursor {
            let jump = e - cursor
            // 往前跳：随便；往回纠：最多 40 字，别乱翻页
            if jump > 0 || -jump <= 40 {
                cursor = e
                stall = 0
                creeped = 0
                lastMatchAt = Date()
                lastSpokenLen = m
                return cursor
            }
        }

        stall += 1
        // 一直在说但一直没对上（口音重 / 环境吵）：按语速慢慢蠕，别让画面僵死
        if stall >= 8 && creeped < 14 && cursor < n - 3
            && Date().timeIntervalSince(lastMatchAt) > 2.0
            && m > lastSpokenLen {
            let add = min(2, m - lastSpokenLen)
            cursor += add
            creeped += add
            lastMatchAt = Date()
            stall = 4
            lastSpokenLen = m
            return cursor
        }
        lastSpokenLen = m
        return cursor
    }

    /// 自由起点编辑距离，返回最合适的「结束位置」，找不到返回 -1
    private func best(_ sp: [Character],
                      _ spPy: [[String]],
                      _ k: Int,
                      _ after: Int,
                      _ win: Int,
                      _ th: Float) -> Int {
        let n = script.norm.count
        let qs = max(0, sp.count - k)
        // 起点要能退到「一个完整探针之前」，否则这次朗读的开头几个字永远对不上
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
                let limit: Float
                if jump > 0 {
                    limit = jump <= 10 ? th : (jump <= 35 ? th * 0.75 : th * 0.45)
                } else {
                    limit = th * 0.28
                }
                if raw <= limit {
                    var rank = raw
                    if jump > 0 { rank += min(0.12, 0.0012 * Float(jump)) }
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
