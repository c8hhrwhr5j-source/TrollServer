import AVFoundation
import UIKit

// ============================================================
//  SilentAudioPlayer - 静音音频保活
//
//  原理：播放一段静音 WAV 无限循环，iOS 判定为音频播放中，
//  给予无限后台运行权限。这是 iOS 后台保活的最高可靠方案。
//
//  特点：
//  - 静音音频几乎零 CPU / 零耗电
//  - 自动处理来电中断（电话结束后自动恢复）
//  - 混音模式，不干扰其他 App 音频
//  - 耳机插拔不影响播放
// ============================================================

final class SilentAudioPlayer: NSObject {

    static let shared = SilentAudioPlayer()

    private var player: AVAudioPlayer?
    private var isConfigured = false

    private override init() {
        super.init()
    }

    // MARK: - 启动

    func start() {
        guard !isConfigured else {
            print("[SilentAudio] 已在运行中")
            return
        }

        // 1. 配置音频会话（混音模式，不打断其他音频）
        configureAudioSession()

        // 2. 生成静音 WAV 并创建播放器
        guard let url = generateSilentWAV() else {
            print("[SilentAudio] ❌ 生成静音文件失败")
            return
        }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1    // 无限循环
            player?.volume = 0.0           // 音量为 0（完全静音）
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()

            isConfigured = true
            print("[SilentAudio] ✅ 静音保活已启动（无限循环，零音量）")
        } catch {
            print("[SilentAudio] ❌ 创建播放器失败: \(error)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isConfigured = false
        print("[SilentAudio] 🛑 已停止")
    }

    // MARK: - 音频会话配置

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback 确保后台播放权限，mixWithOthers 不独占音频
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            print("[SilentAudio] 🔧 音频会话已配置 (playback + mixWithOthers)")
        } catch {
            print("[SilentAudio] ⚠️ 音频会话配置失败: \(error)")
        }
    }

    // MARK: - 生成静音 WAV

    /// 生成 5 秒静音 WAV 文件（16-bit PCM, 8000 Hz, 单声道）
    private func generateSilentWAV() -> URL? {
        let sampleRate: Int32 = 8000
        let duration: Int32 = 5           // 5 秒
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16

        let numSamples = sampleRate * duration
        let dataSize = Int32(numSamples) * Int32(numChannels) * Int32(bitsPerSample / 8)

        // WAV 文件头（44 字节）
        var header = Data()
        // RIFF chunk
        header.append("RIFF".data(using: .ascii)!)
        var fileSize: Int32 = 36 + dataSize
        header.append(Data(bytes: &fileSize, count: 4))
        header.append("WAVE".data(using: .ascii)!)
        // fmt chunk
        header.append("fmt ".data(using: .ascii)!)
        var fmtSize: Int32 = 16
        header.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat: Int16 = 1  // PCM
        header.append(Data(bytes: &audioFormat, count: 2))
        header.append(Data(bytes: &numChannels, count: 2))
        var sr = sampleRate
        header.append(Data(bytes: &sr, count: 4))
        var byteRate: Int32 = sampleRate * Int32(numChannels) * Int32(bitsPerSample / 8)
        header.append(Data(bytes: &byteRate, count: 4))
        var blockAlign: Int16 = numChannels * (bitsPerSample / 8)
        header.append(Data(bytes: &blockAlign, count: 2))
        header.append(Data(bytes: &bitsPerSample, count: 2))
        // data chunk
        header.append("data".data(using: .ascii)!)
        header.append(Data(bytes: &dataSize, count: 4))
        // 静音数据（全零）
        let silentData = Data(repeating: 0, count: Int(dataSize))

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("_silent_bg.wav")
        do {
            try header.write(to: fileURL)
            if let fh = try? FileHandle(forWritingTo: fileURL) {
                fh.seekToEndOfFile()
                fh.write(silentData)
                fh.closeFile()
            }
            print("[SilentAudio] ✅ 静音 WAV 已生成: \(fileURL.path) (\(dataSize/1024) KB)")
            return fileURL
        } catch {
            print("[SilentAudio] ❌ 写入失败: \(error)")
            return nil
        }
    }
}

// MARK: - AVAudioPlayerDelegate（处理中断恢复）

extension SilentAudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // 理论上不会触发（无限循环），但作为安全网
        print("[SilentAudio] ⚠️ 播放结束（非预期），尝试恢复...")
        if isConfigured {
            player.play()
        }
    }

    func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
        print("[SilentAudio] ⚠️ 音频中断（如来电）")
    }

    func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int) {
        print("[SilentAudio] ✅ 音频中断结束，恢复播放")
        if isConfigured {
            player.play()
        }
    }
}
