import Darwin
import Foundation

let cli = VowKyTranscribeCLI()
let exitCode = await cli.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    executablePath: CommandLine.arguments.first
)
Darwin.exit(exitCode)
