package com.psyche.kelivo

import com.google.gson.Gson
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * 执行 Android Shell 命令
 * 对应 Python 版 execute_system_command() — 在 Android 上通过 Process.exec 执行
 */
class ShellTool : Tool {

    private val gson = Gson()

    override val name: String = "execute_system_command"

    override val description: String =
        "在 Android 设备上执行 Shell 命令（通过 Runtime.exec）。注意：命令需要是 Android Shell 支持的格式"

    override val parameters: Map<String, Any> = mapOf(
        "type" to "object",
        "properties" to mapOf(
            "command" to mapOf(
                "type" to "string",
                "description" to "要执行的 Shell 命令，例如: 'ls -la /PATH/TO/FILE' 或 'pm list packages'"
            )
        ),
        "required" to listOf("command")
    )

    override suspend fun execute(args: Map<String, Any>): String {
        val command = args["command"] as? String ?: return "{\"error\": \"缺少 command 参数\"}"

        return try {
            val process = Runtime.getRuntime().exec(arrayOf("sh", "-c", command))
            val stdout = BufferedReader(InputStreamReader(process.inputStream)).readText()
            val stderr = BufferedReader(InputStreamReader(process.errorStream)).readText()
            val exitCode = process.waitFor()

            val output = if (stdout.isNotBlank()) stdout else if (stderr.isNotBlank()) "Error: $stderr" else "命令执行成功（无输出）"

            // 限制输出长度
            val maxLength = 6000
            val truncated = if (output.length > maxLength) {
                "${output.take(maxLength)}\n... (输出被截断，原长度 ${output.length} 字符)"
            } else output

            gson.toJson(mapOf(
                "success" to true,
                "exit_code" to exitCode,
                "output" to truncated
            ))
        } catch (e: Exception) {
            "{\"error\": \"执行失败 - ${e.message}\"}"
        }
    }
}
