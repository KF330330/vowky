import Darwin
import Foundation

// vowky-speechd — VowKy 的常驻语音 helper。
// 主 app 不再链接 onnxruntime;ONNX 推理全部在本进程,W^X(未签名可执行内存)
// 关在这里,主进程活签名保持有效,Sparkle 自更新得以通过 Sequoia/Tahoe 的校验。
//
// 协议:stdin 收长度前缀二进制帧,stdout 回帧(见 SpeechIPCWire)。

// 保存真实 stdout(fd)专供二进制帧;把进程 stdout 重定向到 stderr,
// 这样任何库里残留的 print()/stdout 输出都不会污染帧通道。
let frameOutFD = dup(STDOUT_FILENO)
_ = dup2(STDERR_FILENO, STDOUT_FILENO)

let server = SpeechIPCServer(inputFD: STDIN_FILENO, outputFD: frameOutFD)
server.run()
