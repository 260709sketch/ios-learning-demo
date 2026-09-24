import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Kumone → AMLL 歌词数据转换

/// 将 Kumone 的 `ParsedLyrics` 转换为参考项目 well-music 的 `LyricLineData` 格式。
///
/// 参考项目格式（时间单位均为**秒**，AMLL HTML 内部 Hu() 函数自动转毫秒）：
/// ```
/// {
///   "time": 0.0,
///   "end": 5.0,
///   "lrc": "你好",
///   "index": 0,
///   "words": [
///     { "text": "你", "start": 0.0, "end": 0.3 },
///     { "text": "好", "start": 0.3, "end": 0.8 }
///   ],
///   "translatedLyric": "Hello"
/// }
/// ```
enum AMLLDataConverter {

    /// 转换完整歌词。
    static func convert(_ parsed: ParsedLyrics) -> [[String: Any]] {
        let lines = parsed.lines
        guard !lines.isEmpty else { return [] }

        var result: [[String: Any]] = []
        for (index, line) in lines.enumerated() {
            // 行结束时间：下一行的起始时间，或最后一个字的结束时间
            let lineEnd: TimeInterval
            if index + 1 < lines.count {
                lineEnd = lines[index + 1].time
            } else if let words = line.words, let last = words.last {
                lineEnd = last.end
            } else {
                lineEnd = line.time + 5.0 // 兜底 5 秒
            }

            let words = convertWords(line: line, lineEnd: lineEnd)

            var dict: [String: Any] = [
                "time": line.time,
                "end": lineEnd,
                "lrc": line.text,
                "index": index,
                "words": words,
            ]
            if let translation = line.translation, !translation.isEmpty {
                dict["translatedLyric"] = translation
            }
            result.append(dict)
        }
        return result
    }

    /// 转换逐字数据。如果没有逐字数据，则用整行文本构造一个 word。
    private static func convertWords(line: LyricLine, lineEnd: TimeInterval) -> [[String: Any]] {
        if let words = line.words, !words.isEmpty {
            return words.map { word in
                [
                    "text": word.text,
                    "start": word.start,
                    "end": word.end,
                ]
            }
        }
        // 无逐字数据：整行作为一个 word
        return [
            [
                "text": line.text,
                "start": line.time,
                "end": lineEnd,
            ]
        ]
    }
}

// MARK: - PlatformImage → Base64 Data URL

extension PlatformImage {

    /// 转为 JPEG base64 data URL，供 WKWebView 中的 AMLL WebGL 渲染使用。
    /// data URL 不存在跨域问题，可直接用于 WebGL 纹理。
    func amllJPEGDataURL(compressionQuality: CGFloat = 0.85) -> String? {
        #if os(iOS)
        guard let data = jpegData(compressionQuality: compressionQuality) else { return nil }
        #elseif os(macOS)
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
        else { return nil }
        #endif
        let base64 = data.base64EncodedString(options: [])
        return "data:image/jpeg;base64,\(base64)"
    }
}
