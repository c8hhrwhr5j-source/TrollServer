import Foundation
import Darwin

// ============================================================
//  ShellRunner — iOS 兼容的 shell / 程序执行器
//  使用 posix_spawn 代替 macOS 专属的 Process 类与不可用的 popen
//  (popen / WIFEXITED / WEXITSTATUS 在 iOS SDK 中被 __swift_unavailable)
// ============================================================

func runShellCommand(
    _ command: String,
    environment: [String: String]? = nil
) -> (exitCode: Int32, stdout: String, stderr: String) {
    // 通过 /bin/sh -c 执行; 环境变量以 export 形式前置到命令中
    let prefix: String
    if let env = environment, !env.isEmpty {
        prefix = env.map { "export \($0.key)=\($0.value);" }.joined(separator: " ")
    } else {
        prefix = ""
    }
    let fullCommand = "\(prefix) \(command) 2>&1"

    // 创建用于捕获子进程输出的管道
    var pipeFds = [Int32](repeating: 0, count: 2)
    guard pipe(&pipeFds) == 0 else {
        return (exitCode: -1, stdout: "", stderr: "pipe 失败")
    }
    let readFd = pipeFds[0]
    let writeFd = pipeFds[1]

    // 文件动作: 将子进程的 stdout / stderr 重定向到管道写端
    // 此 SDK 中 posix_spawn_file_actions_t 被导入为 UnsafeMutableRawPointer 别名,
    // 相关函数要求传入 UnsafeMutablePointer<posix_spawn_file_actions_t?>, 故用可选变量 + & 取址
    var fileActions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fileActions)
    posix_spawn_file_actions_adddup2(&fileActions, writeFd, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, writeFd, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, readFd)
    posix_spawn_file_actions_addclose(&fileActions, writeFd)

    // 构造 argv: /bin/sh -c "<command>"
    let argv: [String] = ["/bin/sh", "-c", fullCommand]
    var argvC: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    argvC.append(nil)

    // 构造 envp
    var envpC: [UnsafeMutablePointer<CChar>?]
    if let env = environment, !env.isEmpty {
        envpC = env.map { strdup("\($0.key)=\($0.value)") }
    } else {
        envpC = []
    }
    envpC.append(nil)

    let pathC = strdup("/bin/sh")

    var pid: pid_t = 0
    let spawnStatus = posix_spawn(&pid, pathC, &fileActions, nil, &argvC, &envpC)

    // 释放 strdup 分配的内存
    free(pathC)
    for p in argvC where p != nil { free(p) }
    for p in envpC where p != nil { free(p) }
    posix_spawn_file_actions_destroy(&fileActions)
    close(writeFd)

    if spawnStatus != 0 {
        close(readFd)
        return (exitCode: spawnStatus, stdout: "", stderr: "posix_spawn 失败: \(spawnStatus)")
    }

    // 读取管道内容
    var output = ""
    let bufSize = 4096
    var buffer = [CChar](repeating: 0, count: bufSize)
    while true {
        let n = read(readFd, &buffer, bufSize)
        if n <= 0 { break }
        let data = Data(bytes: buffer, count: Int(n))
        if let s = String(data: data, encoding: .utf8) {
            output += s
        }
    }
    close(readFd)

    // 等待子进程结束
    // 注意: WIFEXITED / WEXITSTATUS 是 C 宏, Swift 中不可用, 按 sys/wait.h 定义手动计算:
    //   #define _WSTATUS(x)  ((x) & 0177)
    //   #define WIFEXITED(x) (_WSTATUS(x) == 0)
    //   #define WEXITSTATUS(x) (((x) >> 8) & 0xff)
    var stat: Int32 = 0
    waitpid(pid, &stat, 0)
    let exitCode: Int32
    if (stat & 0o177) == 0 {
        exitCode = (stat >> 8) & 0xff
    } else {
        exitCode = -1
    }

    return (exitCode: exitCode, stdout: output, stderr: "")
}

func runShellCommandSimple(
    _ command: String,
    environment: [String: String]? = nil
) -> Int32 {
    return runShellCommand(command, environment: environment).exitCode
}

func runProgram(
    _ path: String,
    arguments: [String],
    environment: [String: String]? = nil
) -> (exitCode: Int32, stdout: String, stderr: String) {
    let args = arguments.map { "\"\($0)\"" }.joined(separator: " ")
    let command = args.isEmpty ? path : "\(path) \(args)"
    return runShellCommand(command, environment: environment)
}
