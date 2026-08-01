import Foundation

/// 说话人分离模型的文件名与可用性检查。
/// 主 app(决定开关可用性)与 helper 的 --diarize 模式(定位模型)共用;纯 Foundation,不依赖 ONNX。
enum DiarizationModelCatalog {
    /// pyannote segmentation-3.0(分段)。fp32 版本,2026-07 调研实测验证(int8 未实测,不用)。
    static let segmentationModelFileName = "pyannote-segmentation-3-0.onnx"
    /// 3D-Speaker CAM++ zh-en(声纹)。
    static let embeddingModelFileName = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"

    static let requiredFileNames = [segmentationModelFileName, embeddingModelFileName]

    /// 主 app 侧:两个模型是否都在 bundle 里。
    /// resources 整目录 copy 会把 Models/ 扁平化到 Resources 根,因此两处都查。
    static func availableInBundle(_ bundle: Bundle = .main, fileManager: FileManager = .default) -> Bool {
        guard let resources = bundle.resourceURL else { return false }
        let directories = [resources.appendingPathComponent("Models"), resources]
        return requiredFileNames.allSatisfy { name in
            directories.contains { fileManager.fileExists(atPath: $0.appendingPathComponent(name).path) }
        }
    }
}
