package com.psyche.kelivo

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * 等待工具：AI 可指定等待时长，方便在其他任务未完成时暂停行为等待。
 * 单位：毫秒（ms），范围 1000–300000（1秒–5分钟）。
 */
class WaitTool : Tool {

    override val name: String = "wait"

    override val description: String =
        "等待指定的毫秒数后再继续执行。用于需要暂停等待其他任务完成的场景。" +
        "接受 duration_ms 参数（必填），范围 1000–300000 毫秒（1秒–5分钟）。"

    override val parameters: Map<String, Any> = mapOf(
        "type" to "object",
        "properties" to mapOf(
            "duration_ms" to mapOf(
                "type" to "integer",
                "description" to "等待时长（毫秒），范围 1000–300000（1秒–5分钟）"
            )
        ),
        "required" to listOf("duration_ms")
    )

    override suspend fun execute(args: Map<String, Any>): String {
        val durationMs = (args["duration_ms"] as? Number)?.toInt()
            ?: return """{"error": "缺少 duration_ms 参数"}"""

        val clamped = durationMs.coerceIn(1000, 300000)

        return try {
            withContext(Dispatchers.IO) {
                delay(clamped.toLong())
            }
            """{"success":true,"action":"wait_done","duration_ms":$clamped}"""
        } catch (e: Exception) {
            """{"error": "等待被中断: ${e.message}"}"""
        }
    }
}
