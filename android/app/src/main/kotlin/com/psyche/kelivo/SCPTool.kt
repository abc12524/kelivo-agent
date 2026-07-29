package com.psyche.kelivo

import com.jcraft.jsch.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream

/**
 * SCP 文件传输工具
 * AI 通过此工具向 SSH 服务器上传/下载文件。
 * 所有连接参数由 AI 调用时直接传入。支持密码认证和私钥认证。
 */
class SCPTool : Tool {

    override val name: String = "ssh_scp"

    override val description: String =
        "通过 SCP 向远程服务器传输文件。支持上传（本地→服务器）和下载（服务器→本地）。" +
        "需提供 host/port/username，以及 password 或 private_key 连接参数。"

    override val parameters: Map<String, Any> = mapOf(
        "type" to "object",
        "properties" to mapOf(
            "action" to mapOf(
                "type" to "string",
                "description" to "操作: 'upload'（上传）或 'download'（下载）",
                "enum" to listOf("upload", "download")
            ),
            "host" to mapOf(
                "type" to "string",
                "description" to "SSH 服务器地址（必填）"
            ),
            "port" to mapOf(
                "type" to "string",
                "description" to "SSH 端口（必填）"
            ),
            "username" to mapOf(
                "type" to "string",
                "description" to "SSH 用户名（必填）"
            ),
            "password" to mapOf(
                "type" to "string",
                "description" to "SSH 密码（private_key 和 password 二选一）"
            ),
            "private_key" to mapOf(
                "type" to "string",
                "description" to "SSH 私钥内容（PEM 格式）。private_key / private_key_path / password 三选一"
            ),
            "private_key_path" to mapOf(
                "type" to "string",
                "description" to "私钥文件路径（设备上的文件），程序自动读取。private_key / private_key_path / password 三选一"
            ),
            "passphrase" to mapOf(
                "type" to "string",
                "description" to "私钥的密码短语（仅 private_key 加密时需要，可选）"
            ),
            "local_path" to mapOf(
                "type" to "string",
                "description" to "本地文件路径（upload=源文件，download=保存目标）"
            ),
            "remote_path" to mapOf(
                "type" to "string",
                "description" to "远程路径（upload=目标，download=源文件）"
            )
        ),
        "required" to listOf("action", "host", "port", "username", "local_path", "remote_path")
    )

    override suspend fun execute(args: Map<String, Any>): String {
        val action = args["action"] as? String ?: return """{"error": "缺少 action 参数"}"""
        val host = args["host"] as? String ?: return """{"error": "缺少 host 参数"}"""
        val port = (args["port"] as? Number)?.toInt() ?: (args["port"] as? String)?.toIntOrNull() ?: return """{"error": "缺少 port 参数"}"""
        val username = args["username"] as? String ?: return """{"error": "缺少 username 参数"}"""
        val password = args["password"] as? String
        val privateKey = args["private_key"] as? String
        val privateKeyPath = args["private_key_path"] as? String
        val passphrase = args["passphrase"] as? String
        val localPath = args["local_path"] as? String ?: return """{"error": "缺少 local_path 参数"}"""
        val remotePath = args["remote_path"] as? String ?: return """{"error": "缺少 remote_path 参数"}"""

        // 解析私钥：优先读 private_key_path 文件，其次用 private_key 字符串
        val resolvedKey = when {
            !privateKeyPath.isNullOrBlank() -> try {
                java.io.File(privateKeyPath).readText()
            } catch (e: Exception) {
                return """{"error": "读取私钥文件失败: ${e.message}"}"""
            }
            !privateKey.isNullOrBlank() -> privateKey
            else -> null
        }

        if (password.isNullOrBlank() && resolvedKey.isNullOrBlank()) {
            return """{"error": "缺少认证信息，请提供 password、private_key 或 private_key_path"}"""
        }

        return try {
            when (action) {
                "upload" -> scpUpload(host, port, username, password, resolvedKey, passphrase, localPath, remotePath)
                "download" -> scpDownload(host, port, username, password, resolvedKey, passphrase, localPath, remotePath)
                else -> """{"error": "未知操作: $action，仅支持 upload/download"}"""
            }
        } catch (e: com.jcraft.jsch.JSchException) {
            val detail = when {
                e.message?.contains("Auth fail") == true ->
                    "认证失败：服务器拒绝了提供的凭据。请检查用户名是否正确，私钥/密码是否匹配"
                e.message?.contains("PRIVATE KEY") == true ||
                e.message?.contains("invalid privatekey") == true ->
                    "私钥格式无效：JSch 仅支持 PEM 格式，不支持 OpenSSH 格式"
                else -> "SSH 错误: ${e.message}"
            }
            """{"error": "SCP 操作失败: $detail"}"""
        } catch (e: Exception) {
            """{"error": "SCP 操作失败: ${e.message}"}"""
        }
    }

    /** 创建 SSH 会话（共用） */
    private fun createSession(host: String, port: Int, username: String,
                              password: String?, privateKey: String?, passphrase: String?): Session {
        val jsch = JSch()
        if (!privateKey.isNullOrBlank()) {
            val passphraseBytes = if (!passphrase.isNullOrBlank()) passphrase.toByteArray() else null
            jsch.addIdentity("scp_key_${host}_$port",
                normalizePem(privateKey).toByteArray(), null, passphraseBytes)
        }
        return jsch.getSession(username, host, port).apply {
            if (!password.isNullOrBlank()) setPassword(password)
            setConfig("StrictHostKeyChecking", "no")
            connect(10000)
        }
    }

    private suspend fun scpUpload(host: String, port: Int, username: String,
                                  password: String?, privateKey: String?, passphrase: String?,
                                  localPath: String, remotePath: String): String = withContext(Dispatchers.IO) {
        var session: Session? = null
        var channel: ChannelExec? = null

        try {
            val localFile = File(localPath)
            if (!localFile.exists()) return@withContext """{"error": "本地文件不存在: $localPath"}"""

            session = createSession(host, port, username, password, privateKey, passphrase)

            channel = session.openChannel("exec") as ChannelExec
            channel.setCommand("scp -p -d -t $remotePath")

            val outputStream = channel.outputStream
            val inputStream = channel.inputStream
            channel.connect()

            checkAck(inputStream)
            val cmdBytes = "C0644 ${localFile.length()} ${localFile.name}\n".toByteArray()
            outputStream.write(cmdBytes); outputStream.flush()
            checkAck(inputStream)

            FileInputStream(localFile).use { fis ->
                val buf = ByteArray(1024)
                while (true) { val n = fis.read(buf); if (n <= 0) break; outputStream.write(buf, 0, n) }
            }
            outputStream.write(0); outputStream.flush()
            checkAck(inputStream)

            """{"success":true,"message":"已上传: $localPath -> $remotePath (${localFile.length()} 字节)"}"""
        } finally {
            try { channel?.disconnect() } catch (_: Exception) {}
            try { session?.disconnect() } catch (_: Exception) {}
        }
    }

    private suspend fun scpDownload(host: String, port: Int, username: String,
                                    password: String?, privateKey: String?, passphrase: String?,
                                    localPath: String, remotePath: String): String = withContext(Dispatchers.IO) {
        var session: Session? = null
        var channel: ChannelExec? = null

        try {
            session = createSession(host, port, username, password, privateKey, passphrase)

            channel = session.openChannel("exec") as ChannelExec
            channel.setCommand("scp -f $remotePath")

            val outputStream = channel.outputStream
            val inputStream = channel.inputStream
            channel.connect()

            val buf = ByteArray(1024)
            outputStream.write(0); outputStream.flush()

            var line = ""
            while (true) { val c = inputStream.read(); if (c < 0 || c.toChar() == '\n') break; line += c.toChar() }
            if (!line.startsWith("C")) return@withContext """{"error": "SCP 协议错误: $line"}"""

            val parts = line.substring(1).trim().split(" ")
            val fileSize = parts.getOrNull(1)?.toLongOrNull() ?: 0L

            outputStream.write(0); outputStream.flush()

            val localFile = File(localPath)
            localFile.parentFile?.mkdirs()
            localFile.outputStream().use { fos ->
                var remaining = fileSize
                while (remaining > 0) {
                    val n = inputStream.read(buf, 0, minOf(buf.size.toLong(), remaining).toInt())
                    if (n < 0) break
                    fos.write(buf, 0, n); remaining -= n
                }
            }

            """{"success":true,"message":"已下载: $remotePath -> $localPath (${fileSize} 字节)"}"""
        } finally {
            try { channel?.disconnect() } catch (_: Exception) {}
            try { session?.disconnect() } catch (_: Exception) {}
        }
    }

    private fun checkAck(inputStream: java.io.InputStream) {
        when (val b = inputStream.read()) {
            0 -> {}
            1, 2 -> {
                val sb = StringBuffer(); var c: Int
                while (inputStream.read().also { c = it } > 0) sb.append(c.toChar())
                throw Exception("SCP 错误: $sb")
            }
        }
    }
}
