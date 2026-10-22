package com.psyche.kelivo

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONObject

class ToolsPlugin(private val ctx: Context) {
    private val tools: Map<String, Tool> by lazy {
        mapOf(
            "get_system_info" to SystemInfoTool(),
            "execute_system_command" to ShellTool(),
            "get_gps_location" to GPSTool(ctx),
            "get_sensor_data" to SensorTool(ctx),
            "ssh_execute" to SSHTool(),
            "ssh_scp" to SCPTool(),
            "send_notification" to NotificationTool(),
            "play_sound" to SoundTool(),
        )
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val tool = tools[call.method]
        if (tool == null) {
            result.notImplemented()
            return
        }
        val gson = com.google.gson.Gson()
        val args = if (call.arguments is Map<*, *>) {
            @Suppress("UNCHECKED_CAST")
            (call.arguments as Map<String, Any>)
        } else emptyMap()
        CoroutineScope(Dispatchers.Main).launch {
            try {
                val response = tool.execute(args)
                result.success(response)
            } catch (e: Exception) {
                result.success(JSONObject().apply { put("error", e.message ?: "error") }.toString())
            }
        }
    }
}
