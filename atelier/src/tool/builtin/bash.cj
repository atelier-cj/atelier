package atelier.tool.builtin

import std.fs.*
import std.io.*
import std.process.*
import std.time.*
import std.collection.*
import jsonvalue.*
import atelier.tool.*

/**
 * Execute a shell command.
 * Supports optional timeout in milliseconds.
 */
public class BashTool <: Tool {
    public func name(): String {
        "bash"
    }

    public func description(): String {
        "Execute a shell command and return its stdout output. Supports optional timeout."
    }

    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("command", "Shell command to execute", required: true)
            .addInteger("timeout", "Timeout in milliseconds (optional)")
            .addBoolean("background",
                "Run in background: return immediately and deliver the result later " +
                "(optional; useful for long builds/tests so the conversation is not blocked)")
            .build()
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let command: String = match (args["command"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: command", None, true, false)
        }
        let timeoutMs: Int64 = match (args["timeout"]) {
            case Some(JsonValue.Number(n)) => Int64(n)
            case _ => 0
        }
        let hasTimeout: Bool = match (args["timeout"]) {
            case Some(_) => true
            case None => false
        }

        // 后台模式：立刻返回"已提交"，命令在宿主安排的后台线程里跑，跑完再回填。
        //
        // 为什么需要它：同步执行会让整个 loop 卡住，常驻助手在这期间收不到任何新输入。
        // 没有后台通道时**必须回退同步执行**——不能因为宿主没实现就静默不干活。
        let wantBackground: Bool = match (args["background"]) {
            case Some(JsonValue.Boolean(b)) => b
            case _ => false
        }

        // Determine working directory
        let workDirPath: ?Path
        if (ctx.workDir == "") {
            workDirPath = None
        } else {
            let p = try {
                Path(ctx.workDir)
            } catch (_: Exception) {
                return ToolResult("Invalid working directory path", None, true, false)
            }
            workDirPath = Some(p)
        }

        if (wantBackground) {
            let reqId = newAsyncRequestId(ctx.toolCallId)
            let capturedCmd = command
            let capturedWorkDir = workDirPath
            let work: BackgroundWork = { =>
                let r = runCommandSync(capturedCmd, capturedWorkDir, hasTimeout, timeoutMs)
                (r.text, r.isError)
            }
            if (ctx.submitBackground(reqId, "bash", work)) {
                return asyncToolResult(reqId,
                    "命令已提交后台执行，结果稍后送达（不会阻塞对话）", ctx.toolCallId)
            }
            // 没有后台通道：回退同步执行（下面的正常路径）
        }

        return runCommandSync(command, workDirPath, hasTimeout, timeoutMs)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }
}

// 同步执行一条命令（前台路径与后台工作体共用同一份实现）。
//
// 抽出来的理由：后台模式不能有**第二份**执行逻辑——两份实现迟早分叉，
// 而"后台跑出来的结果和前台不一致"是最难查的那类问题。
func runCommandSync(command: String, workDirPath: ?Path,
    hasTimeout: Bool, timeoutMs: Int64): ToolResult {
    if (hasTimeout && timeoutMs > 0) {
        let proc = try {
            launch("bash", ["-c", command],
                workingDirectory: workDirPath,
                stdOut: ProcessRedirect.Pipe,
                stdErr: ProcessRedirect.Pipe)
        } catch (e: Exception) {
            return ToolResult("Failed to execute command: ${e.message}", None, true, false)
        }

        let timeoutDuration = timeoutMs * Duration.millisecond
        let exitCode = proc.wait(timeout: timeoutDuration)

        let stdout = try {
            readAllFromPipe(proc.stdOutPipe)
        } catch (e: Exception) {
            // 读管道失败被降级成空串，与「命令本来没有输出」不可区分（工具执行面）
            eprintln("[atelier] bash stdout pipe read failed: ${e.toString()}")
            ""
        }

        let stderr = try {
            readAllFromPipe(proc.stdErrPipe)
        } catch (e: Exception) {
            eprintln("[atelier] bash stderr pipe read failed: ${e.toString()}")
            ""
        }

        return buildCommandResult(exitCode, stdout, stderr)
    }
    // Use executeWithOutput for simple case (no timeout)
    let (exitCode, stdoutBytes, stderrBytes) = try {
        executeWithOutput("bash", ["-c", command],
            workingDirectory: workDirPath)
    } catch (e: Exception) {
        return ToolResult("Failed to execute command: ${e.message}", None, true, false)
    }

    let stdout = String.fromUtf8(stdoutBytes)
    let stderr = String.fromUtf8(stderrBytes)

    buildCommandResult(exitCode, stdout, stderr)
}

func readAllFromPipe(inputStream: InputStream): String {
    let reader = StringReader(inputStream)
    reader.readToEnd()
}

func buildCommandResult(exitCode: Int64, stdout: String, stderr: String): ToolResult {
    let output = StringBuilder()
    output.append(stdout)
    if (stderr != "") {
        if (stdout != "") { output.append("\n") }
        output.append("[stderr]\n${stderr}")
    }

    let isError = exitCode != 0
    ToolResult(output.toString(), None, isError, false)
}
