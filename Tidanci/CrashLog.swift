import Foundation
import UIKit

/// 闪退自证。iPhone 上看不到控制台，出问题只能靠用户口述；
/// 这里把「上一次为什么崩」写进沙盒，下次打开 App 在「我的 → 关于」里直接能看。
///
/// 覆盖两类：
/// * Objective-C 异常（AVFoundation / CoreAudio 里最常见的崩溃属于这类，能拿到名字和原因）
/// * 信号（SIGSEGV / SIGABRT 等，拿不到行号，但至少能区分是异常还是野指针）
enum CrashLog {

    private static var fd: Int32 = -1

    static var url: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("last-crash.txt")
    }

    static func install() {
        fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        NSSetUncaughtExceptionHandler { e in
            let text = """
            [异常] \(e.name.rawValue)
            原因：\(e.reason ?? "-")
            调用栈：
            \(e.callStackSymbols.prefix(28).joined(separator: "\n"))

            """
            CrashLog.append(text)
        }

        // 信号处理里不能分配内存（分配器可能已经被崩溃弄坏，会卡死而不是退出），
        // 所以这里只写一句固定文字；真正的原因由上面的异常处理补上。
        gCrashFD = fd
        for s in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(s, crashSignal)
        }
    }

    static func read() -> String? {
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func clear() {
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    fileprivate static func append(_ text: String) {
        let stamped = "\n===== \(Date()) =====\n" + text
        guard let data = stamped.data(using: .utf8) else { return }
        if fd >= 0 {
            _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        } else {
            try? stamped.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private var gCrashFD: Int32 = -1

/// 录制诊断。iPhone 上看不到控制台，「这条为什么没声音」只能靠现场留下的数字：
/// 收到了多少帧音频、备份写了多少字节、成片音轨峰值多少、音频会话是什么类别。
/// 出问题时在「我的 → 关于」里直接能看到，不用再让用户猜。
enum Diag {

    private static let q = DispatchQueue(label: "tidanci.diag")
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static var url: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("audio-diag.txt")
    }

    static func note(_ s: String) {
        let stamp = fmt.string(from: Date())
        q.async {
            var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            text += "[\(stamp)] \(s)\n"
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 160 {
                text = lines.suffix(120).joined(separator: "\n") + "\n"
            }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func read() -> String? {
        q.sync {
            let t = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static func clear() {
        q.async { try? "".write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// 提前备好的字节，信号处理里直接写，不做任何分配
private let gSignalBytes: [UInt8] = Array("\n[信号] 进程被信号终止（闪退）\n".utf8)

/// 信号处理必须是 C 函数指针，不能捕获上下文，也不能在里面分配内存
private func crashSignal(_ sig: Int32) {
    gSignalBytes.withUnsafeBufferPointer { p in
        _ = Darwin.write(gCrashFD >= 0 ? gCrashFD : STDERR_FILENO, p.baseAddress, p.count)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
