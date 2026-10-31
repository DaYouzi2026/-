import Foundation
import AVFoundation
import CoreVideo
import Combine
import UIKit

/// 把处理好的帧写进 mp4。美颜模式下 AVCaptureMovieFileOutput 不能用（它只吃原始帧），
/// 所以自己接 AVAssetWriter。
final class BeautyWriter {
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStart = CMTime.invalid
    private var pending: [CMSampleBuffer] = []
    private let lock = NSLock()

    private(set) var url: URL?

    var pool: CVPixelBufferPool? {
        lock.lock(); defer { lock.unlock() }
        return adaptor?.pixelBufferPool
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return writer?.status == .writing
    }

    func begin(url: URL, width: Int, height: Int, sampleRate: Double, channels: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }

        writer?.cancelWriting()
        writer = nil
        videoIn = nil
        audioIn = nil
        adaptor = nil
        sessionStart = .invalid
        pending.removeAll()
        self.url = url
        try? FileManager.default.removeItem(at: url)

        guard width > 0, height > 0 else { return false }
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }

        let bitrate = max(4_000_000, width * height * 6)
        let vs: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        vi.expectsMediaDataInRealTime = true

        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi,
                                                     sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])

        let rate = sampleRate > 8000 ? sampleRate : 44100
        let ch = (channels > 0 && channels <= 2) ? channels : 1
        let asettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: ch,
            AVEncoderBitRateKey: 128_000
        ]
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: asettings)
        ai.expectsMediaDataInRealTime = true

        guard w.canAdd(vi), w.canAdd(ai) else { return false }
        w.add(vi)
        w.add(ai)
        guard w.startWriting() else { return false }

        writer = w
        videoIn = vi
        audioIn = ai
        adaptor = ad
        return true
    }

    func append(video buffer: CVPixelBuffer, at pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard let w = writer, w.status == .writing, let vi = videoIn, let ad = adaptor else { return }

        if sessionStart == .invalid {
            sessionStart = pts
            w.startSession(atSourceTime: pts)
            if let ai = audioIn {
                for sb in pending {
                    if CMSampleBufferGetPresentationTimeStamp(sb) >= pts, ai.isReadyForMoreMediaData {
                        ai.append(sb)
                    }
                }
            }
            pending.removeAll()
            return
        }

        guard vi.isReadyForMoreMediaData else { return }
        ad.append(buffer, withPresentationTime: pts)
    }

    func append(audio sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let w = writer, w.status == .writing else { return }
        if sessionStart == .invalid {
            if pending.count < 120 { pending.append(sb) }
            return
        }
        guard let ai = audioIn, ai.isReadyForMoreMediaData else { return }
        ai.append(sb)
    }

    func finish(_ done: @escaping (URL?) -> Void) {
        lock.lock()
        guard let w = writer else {
            lock.unlock()
            done(nil)
            return
        }
        let out = url
        let started = sessionStart != .invalid
        writer = nil
        videoIn = nil
        audioIn = nil
        adaptor = nil
        pending.removeAll()
        lock.unlock()

        if !started {
            w.cancelWriting()
            if let o = out { try? FileManager.default.removeItem(at: o) }
            done(nil)
            return
        }

        w.finishWriting {
            let ok = w.status == .completed
            DispatchQueue.main.async { done(ok ? out : nil) }
        }
    }
}
