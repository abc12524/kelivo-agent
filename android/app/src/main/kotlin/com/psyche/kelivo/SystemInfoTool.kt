package com.psyche.kelivo

import android.os.Build
import com.google.gson.Gson

/**
 * 获取 Android 设备系统信息
 * 对应 Python 版 get_system_info()
 */
class SystemInfoTool : Tool {

    private val gson = Gson()

    override val name: String = "get_system_info"

    override val description: String =
        "获取当前 Android 设备的详细信息，包括系统版本、型号、架构等"

    override val parameters: Map<String, Any> = mapOf(
        "type" to "object",
        "properties" to emptyMap<String, Any>(),
        "required" to emptyList<String>()
    )

    override suspend fun execute(args: Map<String, Any>): String {
        val info = mapOf(
            "os" to "Android",
            "os_release" to Build.VERSION.RELEASE,
            "sdk_level" to Build.VERSION.SDK_INT,
            "device" to Build.DEVICE,
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "product" to Build.PRODUCT,
            "brand" to Build.BRAND,
            "board" to Build.BOARD,
            "hardware" to Build.HARDWARE,
            "display" to Build.DISPLAY,
            "java_version" to (System.getProperty("java.version") ?: "unknown")
        )
        return gson.toJson(info)
    }
}
