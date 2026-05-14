import Foundation

/// CLI 二进制自动探测候选目录的统一来源。
/// 含静态常见路径 + 动态扫描 nvm / fnm / volta / nodenv / asdf 等 node 版本管理器目录,
/// 解决 GUI app 启动时 PATH 极窄(没经过 zshrc)、无法找到 nvm 等版本管理器装的 CLI 的问题。
enum CLIPathResolver {

    /// 返回候选目录列表(顺序即优先级)。
    static func candidateDirectories(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        let home = homeDirectory.path
        var dirs: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "/usr/bin",
            "/bin",
        ]
        // nvm: ~/.nvm/versions/node/<ver>/bin
        appendVersionedBins(into: &dirs, root: "\(home)/.nvm/versions/node", suffix: "bin", fm: fileManager)
        // fnm: ~/.fnm/node-versions/<ver>/installation/bin
        appendVersionedBins(into: &dirs, root: "\(home)/.fnm/node-versions", suffix: "installation/bin", fm: fileManager)
        // nodenv: ~/.nodenv/versions/<ver>/bin
        appendVersionedBins(into: &dirs, root: "\(home)/.nodenv/versions", suffix: "bin", fm: fileManager)
        // asdf: ~/.asdf/installs/nodejs/<ver>/bin
        appendVersionedBins(into: &dirs, root: "\(home)/.asdf/installs/nodejs", suffix: "bin", fm: fileManager)
        return dirs
    }

    private static func appendVersionedBins(
        into dirs: inout [String],
        root: String,
        suffix: String,
        fm: FileManager
    ) {
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return }
        // 按文件名倒序：v22 > v20 > v18，新版本优先
        for ver in entries.sorted().reversed() {
            dirs.append("\(root)/\(ver)/\(suffix)")
        }
    }
}
