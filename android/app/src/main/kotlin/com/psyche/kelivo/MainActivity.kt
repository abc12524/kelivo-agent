package com.psyche.kelivo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.net.Uri
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    companion object {
        lateinit var mActivity: MainActivity
    }

    private val processTextChannelName = "app.process_text"
    private val fileSaveChannelName = "app.file_save"
    private var processTextChannel: MethodChannel? = null
    private var fileSaveChannel: MethodChannel? = null
    private var pendingProcessText: String? = null
    private var pythonChannel: MethodChannel? = null
    private var toolsPlugin: ToolsPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mActivity = this
        processTextChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, processTextChannelName)
        processTextChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialText" -> {
                    val text = pendingProcessText ?: extractProcessText(intent)
                    pendingProcessText = null
                    result.success(text)
                }
                else -> result.notImplemented()
            }
        }
        fileSaveChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileSaveChannelName)
        fileSaveChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getDownloadDir" -> {
                    result.success(getExternalFilesDir(null)?.absolutePath)
                }
                else -> result.notImplemented()
            }
        }
        pythonChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.python")
        pythonChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> {
                    PythonManager.initAsync(this)
                    result.success(true)
                }
                "execute" -> {
                    val args = call.arguments as? Map<*, *>
                    val action = args?.get("action") as? String ?: ""
                    val code = args?.get("code") as? String ?: ""
                    val packages = args?.get("packages") as? String ?: ""
                    if (!PythonManager.isReady()) {
                        if (PythonManager.status == PythonManager.InitStatus.FAILED) {
                            result.error("init_failed", "Python init failed: " + PythonManager.getInitError(), null)
                            return@setMethodCallHandler
                        }
                        if (PythonManager.status == PythonManager.InitStatus.NOT_STARTED) {
                            PythonManager.initAsync(this@MainActivity)
                        }
                        val ready = PythonManager.waitForInit(60000)
                        if (!ready) {
                            result.error("init_failed", "Python init failed: " + PythonManager.getInitError(), null)
                            return@setMethodCallHandler
                        }
                    }
                    try {
                        when (action) {
                            "code" -> {
                                val pyResult = PythonManager.executeCode(code)
                                val json = JSONObject()
                                json.put("success", pyResult.success)
                                json.put("output", pyResult.output)
                                json.put("exit_code", pyResult.exitCode)
                                result.success(json.toString())
                            }
                            "script" -> {
                                val path = args?.get("path") as? String ?: ""
                                if (path.isBlank()) {
                                    result.error("invalid_args", "Missing path for script action", null)
                                    return@setMethodCallHandler
                                }
                                val pyResult = PythonManager.executeScript(path)
                                val json = JSONObject()
                                json.put("success", pyResult.success)
                                json.put("output", pyResult.output)
                                json.put("exit_code", pyResult.exitCode)
                                result.success(json.toString())
                            }
                            "pip" -> {
                                val pyResult = PythonManager.pipInstall(packages)
                                val json = JSONObject()
                                json.put("success", pyResult.success)
                                json.put("output", pyResult.output)
                                json.put("exit_code", pyResult.exitCode)
                                result.success(json.toString())
                            }
                            "info" -> {
                                val pyResult = PythonManager.systemInfo()
                                val json = JSONObject()
                                json.put("success", pyResult.success)
                                json.put("output", pyResult.output)
                                json.put("exit_code", pyResult.exitCode)
                                result.success(json.toString())
                            }
                            else -> result.notImplemented()
                        }
                    } catch (e: Exception) {
                        result.error("exec_error", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        toolsPlugin = ToolsPlugin(this)
        val toolsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.tools")
        toolsChannel.setMethodCallHandler { call, result ->
            toolsPlugin?.handle(call, result)
        }

        pendingProcessText = extractProcessText(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = extractProcessText(intent) ?: return
        val ch = processTextChannel
        if (ch != null) {
            ch.invokeMethod("onProcessText", text)
        } else {
            pendingProcessText = text
        }
    }

    private fun extractProcessText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_PROCESS_TEXT) return null
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        return text?.trim()?.takeIf { it.isNotEmpty() }
    }
}
