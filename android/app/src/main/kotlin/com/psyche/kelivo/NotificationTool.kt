package com.psyche.kelivo

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import androidx.core.app.NotificationCompat

/**
 * 状态栏通知工具
 * AI 通过此工具向 Android 状态栏发送通知消息
 */
class NotificationTool : Tool {

    companion object {
        const val CHANNEL_ID = "ai_notifications"
        const val CHANNEL_NAME = "AI 通知"
        private var nextId = 1000

        /**
         * 确保通知渠道已创建（供 Tool 和 Receiver 共用）
         */
        fun ensureChannel(context: Context) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = nm.getNotificationChannel(CHANNEL_ID)
            if (channel == null) {
                val c = NotificationChannel(
                    CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = "AI 助手发送的状态栏通知"
                }
                nm.createNotificationChannel(c)
            }
        }

        /**
         * 推送通知（供 Tool 和 Receiver 共用）
         */
        fun postNotification(
            context: Context,
            title: String,
            content: String,
            priority: Int = NotificationManager.IMPORTANCE_DEFAULT,
            notificationId: Int = nextId++
        ) {
            ensureChannel(context)

            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(content)
                .setPriority(
                    when (priority) {
                        NotificationManager.IMPORTANCE_LOW -> NotificationCompat.PRIORITY_LOW
                        NotificationManager.IMPORTANCE_HIGH -> NotificationCompat.PRIORITY_HIGH
                        NotificationManager.IMPORTANCE_MAX -> NotificationCompat.PRIORITY_MAX
                        else -> NotificationCompat.PRIORITY_DEFAULT
                    }
                )
                .setAutoCancel(true)
                .build()

            nm.notify(notificationId, notification)
        }
    }

    override val name: String = "send_notification"

    override val description: String =
        "向 Android 状态栏发送一条通知消息，用于提醒用户重要信息，如任务完成、定时提醒、系统事件等"

    override val parameters: Map<String, Any> = mapOf(
        "type" to "object",
        "properties" to mapOf(
            "title" to mapOf(
                "type" to "string",
                "description" to "通知标题，简短醒目，如「任务完成」「系统提醒」"
            ),
            "content" to mapOf(
                "type" to "string",
                "description" to "通知正文，详细描述通知内容"
            ),
            "priority" to mapOf(
                "type" to "string",
                "enum" to listOf("low", "default", "high", "max"),
                "description" to "通知优先级（可选，默认 default）。low=低优先级不弹窗，high=高优先级醒目提示，max=紧急"
            )
        ),
        "required" to listOf("title", "content")
    )

    override suspend fun execute(args: Map<String, Any>): String {
        val title = args["title"] as? String ?: return """{"error": "缺少 title 参数"}"""
        val content = args["content"] as? String ?: return """{"error": "缺少 content 参数"}"""
        val priorityStr = args["priority"] as? String ?: "default"

        val priority = when (priorityStr) {
            "low" -> NotificationManager.IMPORTANCE_LOW
            "high" -> NotificationManager.IMPORTANCE_HIGH
            "max" -> NotificationManager.IMPORTANCE_MAX
            else -> NotificationManager.IMPORTANCE_DEFAULT
        }

        val context = com.psyche.kelivo.MainActivity.mActivity
        val notificationId = nextId++

        postNotification(context, title, content, priority, notificationId)

        return """{"success": true, "notification_id": $notificationId, "title": "$title", "content": "$content"}"""
    }
}
