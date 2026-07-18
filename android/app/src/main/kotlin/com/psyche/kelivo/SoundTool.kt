package com.psyche.kelivo

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.ToneGenerator
import android.os.Build

/**
 * 声音播放工具
 * AI 通过此工具播放音调提示音或远程音频文件（如 TTS 语音）
 */
class SoundTool : Tool {

    companion object {
        /** 持有当前正在播放的 MediaPlayer 强引用，防止 GC 导致播放中断 */
        private var currentPlayer: MediaPlayer? = null

        /** 释放当前播放器 */
        private fun releaseCurrent() {
            currentPlayer?.let { mp ->
                try {
                    mp.stop()
                } catch (_: Exception) { }
                mp.release()
            }
            currentPlayer = null
        }
    }

    private val gson = com.google.gson.Gson()

    override val name: String = "play_sound"

    override val description: String =
        "播放声音或音频。支持两种模式：tone=播放指定频率的音调提示音，audio_url=播放远程音频文件（如 TTS 语音链接）"

    override val parameters: Map<String, Any> = mapOf(
        "type" to "object",
        "properties" to mapOf(
            "mode" to mapOf(
                "type" to "string",
                "enum" to listOf("tone", "audio_url"),
                "description" to "声音模式：tone=播放音调提示音，audio_url=播放音频文件（支持远程 http/https 或本地 file:/// 路径）"
            ),
            "frequency" to mapOf(
                "type" to "integer",
                "description" to "音调频率（Hz），仅 mode=tone 时生效。可选值：200=低频嗡声，500=中低频，800=适中，1000=标准提示音（默认），2000=清脆高频，3000=尖锐高频。默认 1000"
            ),
            "duration_ms" to mapOf(
                "type" to "integer",
                "description" to "音调持续时间（毫秒），仅 mode=tone 时生效。默认 500（半秒），最大 5000"
            ),
            "volume" to mapOf(
                "type" to "number",
                "description" to "音量 0.0（静音）~ 1.0（最大），默认 0.5"
            ),
            "url" to mapOf(
                "type" to "string",
                "description" to "音频文件 URL，仅 mode=audio_url 时生效。支持 http/https 远程链接或 file:/// 本地文件路径，如 file:///data/user/0/com.psyche.kelivo/recording.wav"
            ),
            "stream_type" to mapOf(
                "type" to "string",
                "enum" to listOf("notification", "alarm", "music", "ring"),
                "description" to "音频流类型（可选，默认 notification）。notification=通知音，alarm=闹钟音，music=媒体音，ring=来电铃声音"
            )
        ),
        "required" to listOf("mode")
    )

    override suspend fun execute(args: Map<String, Any>): String {
        val mode = args["mode"] as? String ?: return """{"error": "缺少 mode 参数（tone 或 audio_url）"}"""

        return when (mode) {
            "tone" -> playTone(args)
            "audio_url" -> playAudioUrl(args)
            else -> """{"error": "未知 mode: $mode，仅支持 tone 或 audio_url"}"""
        }
    }

    private fun playTone(args: Map<String, Any>): String {
        val frequency = (args["frequency"] as? Number)?.toInt() ?: 1000
        val durationMs = (args["duration_ms"] as? Number)?.toInt()?.coerceIn(50, 5000) ?: 500
        val volume = (args["volume"] as? Number)?.toFloat()?.coerceIn(0f, 1f) ?: 0.5f
        val streamTypeStr = args["stream_type"] as? String ?: "notification"

        val streamType = when (streamTypeStr) {
            "alarm" -> AudioManager.STREAM_ALARM
            "music" -> AudioManager.STREAM_MUSIC
            "ring" -> AudioManager.STREAM_RING
            else -> AudioManager.STREAM_NOTIFICATION
        }

        return try {
            // 将 0.0~1.0 音量映射到 ToneGenerator 的 0~100
            val tgVolume = (volume * 100).toInt().coerceIn(0, 100)

            // 将频率映射到最接近的 ToneGenerator 类型
            val toneType = when {
                frequency < 400 -> ToneGenerator.TONE_PROP_PROMPT
                frequency < 800 -> ToneGenerator.TONE_SUP_RINGTONE
                frequency < 1500 -> ToneGenerator.TONE_PROP_NACK
                frequency < 2500 -> ToneGenerator.TONE_SUP_INTERCEPT
                else -> ToneGenerator.TONE_SUP_INTERCEPT
            }

            val toneGen = ToneGenerator(streamType, tgVolume)
            toneGen.startTone(toneType, durationMs)

            // 等待音调播放完毕（非阻塞，但让 ToneGenerator 有时间处理）
            // 注：startTone 是异步的，durationMs 后自动停止

            """{"success": true, "mode": "tone", "frequency": $frequency, "duration_ms": $durationMs, "volume": $volume, "stream_type": "$streamTypeStr"}"""
        } catch (e: Exception) {
            """{"error": "播放音调失败: ${e.message}"}"""
        }
    }

    private fun playAudioUrl(args: Map<String, Any>): String {
        val url = args["url"] as? String
        if (url.isNullOrBlank()) return """{"error": "缺少 url 参数（音频文件 URL）"}"""

        val volume = (args["volume"] as? Number)?.toFloat()?.coerceIn(0f, 1f) ?: 0.5f
        val streamTypeStr = args["stream_type"] as? String ?: "notification"

        val streamType = when (streamTypeStr) {
            "alarm" -> AudioManager.STREAM_ALARM
            "music" -> AudioManager.STREAM_MUSIC
            "ring" -> AudioManager.STREAM_RING
            else -> AudioManager.STREAM_NOTIFICATION
        }

        return try {
            val context = com.psyche.kelivo.MainActivity.mActivity
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

            // 释放前一个播放器
            releaseCurrent()

            // 音频焦点变化监听器
            val afChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
                when (focusChange) {
                    AudioManager.AUDIOFOCUS_LOSS,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                        // 焦点永久/暂时丢失 → 停止播放并释放
                        releaseCurrent()
                    }
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                        // 可以降低音量继续播放
                        currentPlayer?.setVolume(volume * 0.3f, volume * 0.3f)
                    }
                    AudioManager.AUDIOFOCUS_GAIN -> {
                        // 重新获得焦点 → 恢复音量
                        currentPlayer?.setVolume(volume, volume)
                    }
                }
            }

            // 请求音频焦点（持续持有，直到播放完毕）
            val focusResult = audioManager.requestAudioFocus(
                afChangeListener,
                streamType,
                AudioManager.AUDIOFOCUS_GAIN
            )

            if (focusResult != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                return """{"error": "无法获取音频焦点，可能正在播放其他音频"}"""
            }

            val mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(when (streamTypeStr) {
                            "alarm" -> AudioAttributes.USAGE_ALARM
                            "ring" -> AudioAttributes.USAGE_NOTIFICATION_RINGTONE
                            "music" -> AudioAttributes.USAGE_MEDIA
                            else -> AudioAttributes.USAGE_NOTIFICATION
                        })
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                setDataSource(url)
                setVolume(volume, volume)
                setOnCompletionListener {
                    // 播放完成 → 释放焦点和播放器
                    try {
                        audioManager.abandonAudioFocus(afChangeListener)
                    } catch (_: Exception) { }
                    releaseCurrent()
                }
                setOnErrorListener { _, _, _ ->
                    try {
                        audioManager.abandonAudioFocus(afChangeListener)
                    } catch (_: Exception) { }
                    releaseCurrent()
                    true
                }
                prepare()
                start()
            }

            // 持有强引用，防止 GC
            currentPlayer = mediaPlayer

            """{"success": true, "mode": "audio_url", "url": "$url", "volume": $volume, "stream_type": "$streamTypeStr", "focus_result": $focusResult}"""
        } catch (e: Exception) {
            releaseCurrent()
            """{"error": "播放音频失败: ${e.message}"}"""
        }
    }

    private fun playLocal(args: Map<String, Any>): String {
        val path = args["path"] as? String
        if (path.isNullOrBlank()) return """{"error": "缺少 path 参数（本地音频文件路径）"}"""

        val volume = (args["volume"] as? Number)?.toFloat()?.coerceIn(0f, 1f) ?: 0.5f
        val streamTypeStr = args["stream_type"] as? String ?: "notification"

        val streamType = when (streamTypeStr) {
            "alarm" -> AudioManager.STREAM_ALARM
            "music" -> AudioManager.STREAM_MUSIC
            "ring" -> AudioManager.STREAM_RING
            else -> AudioManager.STREAM_NOTIFICATION
        }

        return try {
            val context = com.psyche.kelivo.MainActivity.mActivity
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

            releaseCurrent()

            val afChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
                when (focusChange) {
                    AudioManager.AUDIOFOCUS_LOSS,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> releaseCurrent()
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                        currentPlayer?.setVolume(volume * 0.3f, volume * 0.3f)
                    }
                    AudioManager.AUDIOFOCUS_GAIN -> {
                        currentPlayer?.setVolume(volume, volume)
                    }
                }
            }

            val focusResult = audioManager.requestAudioFocus(
                afChangeListener, streamType, AudioManager.AUDIOFOCUS_GAIN
            )

            if (focusResult != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                return """{"error": "无法获取音频焦点，可能正在播放其他音频"}"""
            }

            val file = java.io.File(path)
            if (!file.exists()) return """{"error": "文件不存在: $path"}"""

            val mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(when (streamTypeStr) {
                            "alarm" -> AudioAttributes.USAGE_ALARM
                            "ring" -> AudioAttributes.USAGE_NOTIFICATION_RINGTONE
                            "music" -> AudioAttributes.USAGE_MEDIA
                            else -> AudioAttributes.USAGE_NOTIFICATION
                        })
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                setDataSource(file.absolutePath)
                setVolume(volume, volume)
                setOnCompletionListener {
                    try { audioManager.abandonAudioFocus(afChangeListener) } catch (_: Exception) { }
                    releaseCurrent()
                }
                setOnErrorListener { _, _, _ ->
                    try { audioManager.abandonAudioFocus(afChangeListener) } catch (_: Exception) { }
                    releaseCurrent()
                    true
                }
                prepare()
                start()
            }

            currentPlayer = mediaPlayer

            """{"success": true, "mode": "local", "path": "$path", "volume": $volume, "stream_type": "$streamTypeStr"}"""
        } catch (e: Exception) {
            releaseCurrent()
            """{"error": "播放本地音频失败: ${e.message}"}"""
        }
    }
}
