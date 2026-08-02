import Foundation

/// 说话人分离模型的文件名与可用性检查。
/// 主 app(决定开关可用性)与 helper 的 --diarize 模式(定位模型)共用;纯 Foundation,不依赖 ONNX。
/// 分离聚类调参（helper 子进程与测试共用）。
enum DiarizationTuning {
    /// 说话人自动估计的聚类阈值（余弦距离，越大越倾向合并成更少说话人）。
    /// 2026-08-02 双音频扫描定为 0.7：短句多的真实对话（真实 2 人）0.5 时过分裂成 6 人、
    /// 0.7 降到 4 人，同时四人基准音频在 0.7 仍正确估计 4 人（0.8 起基准开始误合并）。
    /// 短句（<1s）声纹本就不可靠，自动估计有天花板——已知人数时用「说话人数」选项强制指定更准。
    static let clusteringThreshold: Float = 0.7
}

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
