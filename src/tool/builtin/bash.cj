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

        if (hasTimeout && timeoutMs > 0) {
            // Use launch + wait with timeout
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
            } catch (_: Exception) {
                ""
            }

            let stderr = try {
                readAllFromPipe(proc.stdErrPipe)
            } catch (_: Exception) {
                ""
            }

            return buildCommandResult(exitCode, stdout, stderr)
        } else {
            // Use executeWithOutput for simple case (no timeout)
            let (exitCode, stdoutBytes, stderrBytes) = try {
                executeWithOutput("bash", ["-c", command],
                    workingDirectory: workDirPath)
            } catch (e: Exception) {
                return ToolResult("Failed to execute command: ${e.message}", None, true, false)
            }

            let stdout = String.fromUtf8(stdoutBytes)
            let stderr = String.fromUtf8(stderrBytes)

            return buildCommandResult(exitCode, stdout, stderr)
        }
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }
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
