import Foundation

enum AISkillPlatform: String, CaseIterable, Identifiable {
    case codex
    case claudeCode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude Code"
        }
    }
}

enum AISkillInstallState: Equatable {
    case notInstalled
    case installed(version: String?)
    case blockedByUnmanagedSkill
}

struct AISkillPlatformStatus: Equatable {
    let platform: AISkillPlatform
    let skillDirectory: URL
    let state: AISkillInstallState
}

struct AISkillUninstallResult: Equatable {
    let removedSkillDirectories: [URL]
    let removedCompletedJobCaches: Int
}

enum AISkillInstallerError: LocalizedError, Equatable {
    case noPlatformsSelected
    case helperMissing(String)
    case unmanagedSkillExists(String)

    var errorDescription: String? {
        switch self {
        case .noPlatformsSelected:
            return "请选择至少一个要安装的 AI 工具"
        case .helperMissing(let path):
            return "未找到 VowKy 转录 helper：\(path)"
        case .unmanagedSkillExists(let path):
            return "已存在同名但不是 VowKy 管理的 skill，未覆盖：\(path)"
        }
    }
}

final class AISkillInstallerService {
    static let skillName = "vowky-transcribe"
    static let skillVersion = "1.0.1"

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let environment: [String: String]
    private let appBundleURL: URL
    private let helperURLOverride: URL?
    private let transcriptionJobsRootOverride: URL?

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appBundleURL: URL = Bundle.main.bundleURL,
        helperURLOverride: URL? = nil,
        transcriptionJobsRootOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.appBundleURL = appBundleURL
        self.helperURLOverride = helperURLOverride
        self.transcriptionJobsRootOverride = transcriptionJobsRootOverride
    }

    func statuses() -> [AISkillPlatformStatus] {
        AISkillPlatform.allCases.map { status(for: $0) }
    }

    func status(for platform: AISkillPlatform) -> AISkillPlatformStatus {
        let directory = skillDirectory(for: platform)

        guard fileManager.fileExists(atPath: directory.path) else {
            return AISkillPlatformStatus(platform: platform, skillDirectory: directory, state: .notInstalled)
        }

        guard let marker = readMarker(in: directory), marker.managedBy == "VowKy" else {
            return AISkillPlatformStatus(platform: platform, skillDirectory: directory, state: .blockedByUnmanagedSkill)
        }

        return AISkillPlatformStatus(platform: platform, skillDirectory: directory, state: .installed(version: marker.version))
    }

    @discardableResult
    func install(platforms: Set<AISkillPlatform>) throws -> [URL] {
        guard !platforms.isEmpty else {
            throw AISkillInstallerError.noPlatformsSelected
        }

        let helperURL = resolvedHelperURL()
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            throw AISkillInstallerError.helperMissing(helperURL.path)
        }

        var installedDirectories: [URL] = []
        for platform in platforms {
            let directory = skillDirectory(for: platform)
            let status = status(for: platform)
            if status.state == .blockedByUnmanagedSkill {
                throw AISkillInstallerError.unmanagedSkillExists(directory.path)
            }

            try replaceManagedSkill(at: directory, helperURL: helperURL)
            installedDirectories.append(directory)
        }
        return installedDirectories
    }

    @discardableResult
    func uninstall(platforms: Set<AISkillPlatform>) throws -> AISkillUninstallResult {
        guard !platforms.isEmpty else {
            throw AISkillInstallerError.noPlatformsSelected
        }

        var directoriesToRemove: [URL] = []
        for platform in platforms {
            let directory = skillDirectory(for: platform)
            guard fileManager.fileExists(atPath: directory.path) else { continue }

            guard readMarker(in: directory)?.managedBy == "VowKy" else {
                throw AISkillInstallerError.unmanagedSkillExists(directory.path)
            }

            directoriesToRemove.append(directory)
        }

        var removedDirectories: [URL] = []
        for directory in directoriesToRemove {
            try fileManager.removeItem(at: directory)
            removedDirectories.append(directory)
        }

        let removedJobCaches = try cleanupFinishedTranscriptionJobs()
        return AISkillUninstallResult(
            removedSkillDirectories: removedDirectories,
            removedCompletedJobCaches: removedJobCaches
        )
    }

    func skillDirectory(for platform: AISkillPlatform) -> URL {
        switch platform {
        case .codex:
            let codexHome = environment["CODEX_HOME"].map(expandHomePath)
                ?? homeDirectory.appendingPathComponent(".codex")
            return codexHome
                .appendingPathComponent("skills")
                .appendingPathComponent(Self.skillName)
        case .claudeCode:
            return homeDirectory
                .appendingPathComponent(".claude")
                .appendingPathComponent("skills")
                .appendingPathComponent(Self.skillName)
        }
    }

    private func replaceManagedSkill(at directory: URL, helperURL: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }

        let scriptsDirectory = directory.appendingPathComponent("scripts")
        let agentsDirectory = directory.appendingPathComponent("agents")
        try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)

        try skillMarkdown()
            .write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try launcherScript(helperURL: helperURL)
            .write(to: scriptsDirectory.appendingPathComponent("vowky-transcribe.sh"), atomically: true, encoding: .utf8)
        try openAIYAML()
            .write(to: agentsDirectory.appendingPathComponent("openai.yaml"), atomically: true, encoding: .utf8)

        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptsDirectory.appendingPathComponent("vowky-transcribe.sh").path
        )

        let marker = AISkillManagedMarker(
            managedBy: "VowKy",
            skillName: Self.skillName,
            version: Self.skillVersion,
            helperPath: helperURL.path,
            installedAt: ISO8601DateFormatter().string(from: Date())
        )
        let data = try JSONEncoder().encode(marker)
        try data.write(to: directory.appendingPathComponent(".vowky-managed"), options: .atomic)
    }

    private func readMarker(in directory: URL) -> AISkillManagedMarker? {
        let markerURL = directory.appendingPathComponent(".vowky-managed")
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(AISkillManagedMarker.self, from: data)
    }

    private func resolvedHelperURL() -> URL {
        helperURLOverride
            ?? appBundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Helpers")
                .appendingPathComponent("vowky-transcribe")
    }

    func cleanupFinishedTranscriptionJobs() throws -> Int {
        let jobsRoot = transcriptionJobsRoot()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: jobsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return 0
        }

        let jobDirectories = try fileManager.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        var removedCount = 0
        for jobDirectory in jobDirectories {
            var isJobDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: jobDirectory.path, isDirectory: &isJobDirectory),
                  isJobDirectory.boolValue
            else {
                continue
            }

            let statusFile = jobDirectory.appendingPathComponent("status.env")
            guard let state = statusState(in: statusFile), ["succeeded", "failed"].contains(state) else {
                continue
            }

            try fileManager.removeItem(at: jobDirectory)
            removedCount += 1
        }

        if (try? fileManager.contentsOfDirectory(atPath: jobsRoot.path).isEmpty) == true {
            try? fileManager.removeItem(at: jobsRoot)
        }

        return removedCount
    }

    private func transcriptionJobsRoot() -> URL {
        if let transcriptionJobsRootOverride {
            return transcriptionJobsRootOverride
        }

        let tempDirectory = environment["TMPDIR"] ?? "/tmp"
        return URL(fileURLWithPath: tempDirectory, isDirectory: true)
            .appendingPathComponent("vowky-transcribe-jobs", isDirectory: true)
    }

    private func statusState(in statusFile: URL) -> String? {
        guard let statusText = try? String(contentsOf: statusFile, encoding: .utf8) else {
            return nil
        }

        return statusText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("state=") }
            .map { String($0.dropFirst("state=".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func expandHomePath(_ path: String) -> URL {
        let expandedPath = (path as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }
        return homeDirectory.appendingPathComponent(expandedPath)
    }

    private func skillMarkdown() -> String {
        """
        ---
        name: vowky-transcribe
        description: Start background transcription of local audio or video files with VowKy's offline speech model and save .txt transcripts into the current working directory. Use when the user asks to transcribe audio/video files, create transcripts, or run VowKy transcription from Codex or Claude Code.
        ---

        # VowKy Transcribe

        Transcribe local audio or video files using the VowKy helper installed on this Mac. The default workflow starts a background job and returns immediately so the user can keep chatting.

        ## Workflow

        1. Resolve all user-supplied input paths relative to the current working directory.
        2. Start the bundled launcher from the current working directory. This returns immediately with `STARTED`, `STATUS`, and `OUTPUT_DIR` lines:

        ```bash
        SKILL_DIR="${CLAUDE_SKILL_DIR:-${CODEX_HOME:-$HOME/.codex}/skills/vowky-transcribe}"
        if [ ! -x "$SKILL_DIR/scripts/vowky-transcribe.sh" ] && [ -x "$HOME/.claude/skills/vowky-transcribe/scripts/vowky-transcribe.sh" ]; then
          SKILL_DIR="$HOME/.claude/skills/vowky-transcribe"
        fi
        "$SKILL_DIR/scripts/vowky-transcribe.sh" --background --output-dir "$PWD" -- <audio-or-video> [more-files...]
        ```

        3. Tell the user the transcription has started in the background and they can continue working. Do not wait in the foreground.
        4. Check completion later with:

        ```bash
        "$SKILL_DIR/scripts/vowky-transcribe.sh" --status <status-file-from-STARTED-output>
        ```

        If the status is `RUNNING`, continue the conversation normally and check again later. If proactive follow-ups/heartbeats are available, schedule a short follow-up to check the status file and reschedule until it is done.
        5. When the status is `DONE`, report only generated transcript paths. When it is `FAILED`, report failed items. Do not paste full transcript text unless the user explicitly asks for it.
        6. Leave the generated `.txt` files in the current working directory. Do not move them to a project root, a `transcripts/` folder, or a temp directory.

        ## Foreground Mode

        Use `--foreground` only for explicit debugging or tests:

        ```bash
        "$SKILL_DIR/scripts/vowky-transcribe.sh" --foreground --output-dir "$PWD" -- <audio-or-video>
        ```

        ## Supported Inputs

        Use one or more local audio/video files, including wav, mp3, m4a, aac, aiff, flac, mp4, mov, and m4v.
        """
    }

    private func launcherScript(helperURL: URL) -> String {
        let helperPath = shellSingleQuote(helperURL.path)
        return """
        #!/bin/bash
        set -euo pipefail

        installed_helper=\(helperPath)

        usage() {
          cat <<'USAGE'
        Usage:
          vowky-transcribe.sh [--background] [--output-dir DIR] -- FILE [MORE_FILES...]
          vowky-transcribe.sh --foreground [--output-dir DIR] -- FILE [MORE_FILES...]
          vowky-transcribe.sh --status STATUS_FILE

        Default mode is --background. Transcripts are written to DIR, or to the current directory.
        USAGE
        }

        find_helper() {
          if [ -n "${VOWKY_TRANSCRIBE_HELPER:-}" ] && [ -x "$VOWKY_TRANSCRIBE_HELPER" ]; then
            printf '%s\\n' "$VOWKY_TRANSCRIBE_HELPER"
            return 0
          fi

          for candidate in "$installed_helper" "/Applications/VowKy.app/Contents/Helpers/vowky-transcribe" "$HOME/Applications/VowKy.app/Contents/Helpers/vowky-transcribe"; do
            if [ -n "$candidate" ] && [ -x "$candidate" ]; then
              printf '%s\\n' "$candidate"
              return 0
            fi
          done

          return 1
        }

        status_value() {
          local key="$1"
          local file="$2"
          awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; found=1 } END { exit found ? 0 : 1 }' "$file"
        }

        print_status() {
          local status_file="$1"
          if [ ! -f "$status_file" ]; then
            printf 'MISSING\\t%s\\n' "$status_file"
            return 1
          fi

          local state job_id output_dir log_file
          state="$(status_value state "$status_file" || printf unknown)"
          job_id="$(status_value job_id "$status_file" || true)"
          output_dir="$(status_value output_dir "$status_file" || true)"
          log_file="$(status_value log_file "$status_file" || true)"

          case "$state" in
            running)
              printf 'RUNNING\\t%s\\t%s\\n' "$job_id" "$output_dir"
              ;;
            succeeded)
              printf 'DONE\\t%s\\t%s\\n' "$job_id" "$output_dir"
              awk 'BEGIN { tab=sprintf("%c", 9) } index($0, "wrote=") == 1 { print "WROTE" tab substr($0, 7) }' "$status_file"
              ;;
            failed)
              printf 'FAILED\\t%s\\t%s\\n' "$job_id" "$output_dir"
              awk 'BEGIN { tab=sprintf("%c", 9) } index($0, "wrote=") == 1 { print "WROTE" tab substr($0, 7) }' "$status_file"
              awk 'BEGIN { tab=sprintf("%c", 9) } index($0, "failed=") == 1 { print "FAILED" tab substr($0, 8) }' "$status_file"
              ;;
            *)
              printf 'UNKNOWN\\t%s\\n' "$status_file"
              ;;
          esac

          if [ -n "$log_file" ]; then
            printf 'LOG\\t%s\\n' "$log_file"
          fi
        }

        write_running_status() {
          local status_file="$1"
          local tmp="${status_file}.tmp"
          {
            printf 'state=running\\n'
            printf 'job_id=%s\\n' "$job_id"
            printf 'output_dir=%s\\n' "$output_dir"
            printf 'status_file=%s\\n' "$status_file"
            printf 'log_file=%s\\n' "$log_file"
            printf 'input_count=%s\\n' "$input_count"
            printf 'started_at=%s\\n' "$started_at"
          } > "$tmp"
          mv "$tmp" "$status_file"
        }

        write_finished_status() {
          local state="$1"
          local exit_code="$2"
          local finished_at="$3"
          local status_file="$4"
          local tmp="${status_file}.tmp"
          {
            printf 'state=%s\\n' "$state"
            printf 'job_id=%s\\n' "$job_id"
            printf 'output_dir=%s\\n' "$output_dir"
            printf 'status_file=%s\\n' "$status_file"
            printf 'log_file=%s\\n' "$log_file"
            printf 'input_count=%s\\n' "$input_count"
            printf 'started_at=%s\\n' "$started_at"
            printf 'finished_at=%s\\n' "$finished_at"
            printf 'exit_code=%s\\n' "$exit_code"
            if [ -s "$stdout_file" ]; then
              awk 'BEGIN { tab=sprintf("%c", 9) } index($0, "WROTE" tab) == 1 { print "wrote=" substr($0, 7) }' "$stdout_file"
            fi
            if [ -s "$stderr_file" ]; then
              awk 'BEGIN { tab=sprintf("%c", 9) } index($0, "FAILED" tab) == 1 { print "failed=" substr($0, 8) }' "$stderr_file"
            fi
          } > "$tmp"
          mv "$tmp" "$status_file"

          {
            if [ -s "$stdout_file" ]; then cat "$stdout_file"; fi
            if [ -s "$stderr_file" ]; then cat "$stderr_file"; fi
          } > "$log_file"
        }

        if [ "${1:-}" = "--_worker" ]; then
          helper="$2"
          output_dir="$3"
          job_id="$4"
          status_file="$5"
          stdout_file="$6"
          stderr_file="$7"
          log_file="$8"
          input_count="$9"
          started_at="${10}"
          shift 10
          if [ "${1:-}" = "--" ]; then
            shift
          fi

          set +e
          "$helper" --output-dir "$output_dir" -- "$@" > "$stdout_file" 2> >(awk 'BEGIN { tab=sprintf("%c", 9) } index($0, "FAILED" tab) == 1 { print }' > "$stderr_file")
          exit_code=$?
          set -e

          if [ "$exit_code" -eq 0 ]; then
            state="succeeded"
          else
            state="failed"
          fi
          finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
          write_finished_status "$state" "$exit_code" "$finished_at" "$status_file"
          exit 0
        fi

        if [ "${1:-}" = "--status" ]; then
          if [ -z "${2:-}" ]; then
            echo "Missing status file." >&2
            exit 2
          fi
          print_status "$2"
          exit 0
        fi

        helper="$(find_helper || true)"
        if [ -z "$helper" ]; then
          echo "VowKy transcribe helper was not found. Open VowKy Settings and reinstall the AI skill." >&2
          exit 127
        fi

        mode="background"
        output_dir="$PWD"

        while [ "$#" -gt 0 ]; do
          case "$1" in
            --background)
              mode="background"
              shift
              ;;
            --foreground)
              mode="foreground"
              shift
              ;;
            --output-dir)
              if [ -z "${2:-}" ]; then
                echo "Missing value for --output-dir." >&2
                exit 2
              fi
              output_dir="$2"
              shift 2
              ;;
            --help|-h)
              usage
              exit 0
              ;;
            --)
              shift
              break
              ;;
            -*)
              echo "Unknown option: $1" >&2
              usage >&2
              exit 2
              ;;
            *)
              break
              ;;
          esac
        done

        if [ "$#" -eq 0 ]; then
          echo "No audio or video files were provided." >&2
          usage >&2
          exit 2
        fi

        case "$output_dir" in
          "~")
            output_dir="$HOME"
            ;;
          "~/"*)
            output_dir="$HOME/${output_dir#~/}"
            ;;
        esac
        mkdir -p "$output_dir"
        output_dir="$(cd "$output_dir" && pwd -P)"

        if [ "$mode" = "foreground" ]; then
          exec "$helper" --output-dir "$output_dir" -- "$@"
        fi

        jobs_root="${TMPDIR:-/tmp}/vowky-transcribe-jobs"
        mkdir -p "$jobs_root"
        job_id="$(date -u +"%Y%m%d-%H%M%S")-$$-$RANDOM"
        job_dir="$jobs_root/$job_id"
        mkdir -p "$job_dir"
        status_file="$job_dir/status.env"
        stdout_file="$job_dir/stdout.events"
        stderr_file="$job_dir/stderr.events"
        log_file="$job_dir/events.log"
        input_count="$#"
        started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

        write_running_status "$status_file"

        nohup "$0" --_worker "$helper" "$output_dir" "$job_id" "$status_file" "$stdout_file" "$stderr_file" "$log_file" "$input_count" "$started_at" -- "$@" >/dev/null 2>&1 &

        printf 'STARTED\\t%s\\n' "$job_id"
        printf 'STATUS\\t%s\\n' "$status_file"
        printf 'OUTPUT_DIR\\t%s\\n' "$output_dir"
        """
    }

    private func openAIYAML() -> String {
        """
        interface:
          display_name: "VowKy Transcribe"
          short_description: "Background offline audio/video transcription"
          default_prompt: "Use $vowky-transcribe to start a background transcription job for local audio or video files into .txt files."
        """
    }

    private func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private struct AISkillManagedMarker: Codable, Equatable {
    let managedBy: String
    let skillName: String
    let version: String
    let helperPath: String
    let installedAt: String
}
