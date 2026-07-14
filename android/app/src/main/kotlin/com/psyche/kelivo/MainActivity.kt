package com.psyche.kelivo

import android.app.Activity
import android.content.ActivityNotFoundException
import android.net.Uri
import android.content.Intent
import androidx.activity.result.contract.ActivityResultContracts
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
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSourcePath: String? = null
    private var pythonChannel: MethodChannel? = null
    private var toolsPlugin: ToolsPlugin? = null

    private val createDocumentLauncher = registerForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip")
    ) { uri: Uri? -> onSaveDocumentResult(uri) }

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
                "saveFileFromPath" -> handleSaveFileFromPath(call.arguments, result)
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

    private fun handleSaveFileFromPath(arguments: Any?, result: MethodChannel.Result) {
        if (pendingSaveResult != null) {
            result.error("busy", "Another save operation is already in progress.", null)
            return
        }

        val args = arguments as? Map<*, *>
        val rawSourcePath = args?.get("sourcePath")?.toString()?.trim().orEmpty()
        if (rawSourcePath.isEmpty()) {
            result.error("invalid_args", "Missing sourcePath.", null)
            return
        }

        val sourceFile = File(rawSourcePath)
        if (!sourceFile.exists() || !sourceFile.isFile) {
            result.error("not_found", "Source file does not exist.", null)
            return
        }

        val suggestedFileName = args?.get("fileName")?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
            ?: sourceFile.name

        pendingSaveResult = result
        pendingSaveSourcePath = sourceFile.absolutePath

        try {
            createDocumentLauncher.launch(suggestedFileName)
        } catch (e: ActivityNotFoundException) {
            pendingSaveResult = null
            pendingSaveSourcePath = null
            result.error("launch_failed", e.message, null)
        }
    }

    private fun onSaveDocumentResult(destUri: Uri?) {
        val result = pendingSaveResult ?: return
        val sourcePath = pendingSaveSourcePath

        if (destUri == null || sourcePath.isNullOrBlank()) {
            pendingSaveResult = null
            pendingSaveSourcePath = null
            result.success(false)
            return
        }

        Thread {
            try {
                contentResolver.openOutputStream(destUri)?.use { outputStream ->
                    FileInputStream(File(sourcePath)).use { inputStream ->
                        inputStream.copyTo(outputStream, DEFAULT_BUFFER_SIZE)
                    }
                } ?: throw IllegalStateException("Unable to open destination stream.")

                runOnUiThread {
                    pendingSaveResult = null
                    pendingSaveSourcePath = null
                    result.success(true)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    pendingSaveResult = null
                    pendingSaveSourcePath = null
                    result.error("save_failed", e.message, null)
                }
            }
        }.start()
    }
}
