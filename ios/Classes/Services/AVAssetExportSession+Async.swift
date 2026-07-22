import Foundation
import AVFoundation

// MARK: - AVAssetExportSession 异步导出

extension AVAssetExportSession {

    /// 以 async/await 方式导出，内部用 `withCheckedThrowingContinuation` 包装
    /// `exportAsynchronously`（系统的 `export(to:as:)` 仅 iOS 18+ 可用，本插件最低支持 iOS 15）。
    ///
    /// VideoExporter 与 LivePhotoExtractor 原先各自复制了一份同样的包装代码，
    /// 这里统一抽出；两边的错误语义差异由 `fallbackError` 注入保留：
    /// 导出失败时优先抛出系统的 `error`，系统未提供时才抛出调用方的兜底错误。
    ///
    /// - Parameter fallbackError: 声明为 `@autoclosure`，保持与原先
    ///   `exportSession.error ?? <兜底错误>` 一致的惰性语义——导出成功时
    ///   不会构造这个 NSError。
    ///
    /// - Note: 方法名刻意避开系统的 `export(to:as:)`，避免与 iOS 18+ SDK 的同名 API 冲突。
    func exportAsync(
        to outputURL: URL,
        as fileType: AVFileType,
        fallbackError: @autoclosure @escaping () -> Error
    ) async throws {
        self.outputURL = outputURL
        self.outputFileType = fileType
        // 说明：AVAssetExportSession 被系统标记为 non-Sendable，在 @Sendable 完成回调里
        // 捕获它会产生一条并发告警。这里刻意保留该告警，不使用 `nonisolated(unsafe)` 消除——
        // 后者需要 Swift 5.10 / Xcode 15.3+，而本插件 podspec 声明 swift_version 5.9，
        // 为消一条无害告警而抬高使用方的工具链门槛并不划算。
        // 回调由系统在导出结束后单线程调用，此处捕获是安全的（与抽取前的两份原始代码一致）。
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.exportAsynchronously {
                if self.status == .completed {
                    cont.resume()
                } else {
                    cont.resume(throwing: self.error ?? fallbackError())
                }
            }
        }
    }
}
