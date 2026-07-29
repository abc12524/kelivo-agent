import "dart:convert";
import "baidu_qianfan/baidu_qianfan_service.dart";
import "package:flutter/services.dart";
import "package:permission_handler/permission_handler.dart";
import "notification_service.dart";

/// Service that provides device tools (GPS, sensor, shell, SSH, etc.)
/// Communicates with native Android code via MethodChannel
class DeviceToolsService {
  static const _toolsChannel = MethodChannel("app.tools");
  static const _pythonChannel = MethodChannel("app.python");

  /// Get all tool definitions in OpenAI function-calling format
  static List<Map<String, dynamic>> getToolDefinitions() {
    return [
      _def(
        "get_system_info",
        "Get device system info: OS version, SDK level, device model, manufacturer, etc. No arguments needed.",
        {},
      ),
      _def(
        "execute_system_command",
        "Execute a shell command on the Android device via sh -c. Use for file operations, process management, system queries.",
        {"command": {"type": "string", "description": "Shell command to execute, e.g. \"ls -la /sdcard\""}},
        ["command"],
      ),
      _def(
        "get_gps_location",
        "Get current GPS location (lat/lng/accuracy). Requires location permission. Returns lat, lng, accuracy in meters.",
        {},
      ),
      _def(
        "get_sensor_data",
        "Read Android device sensor data. sensor=all lists all available sensors. Specify sensor for one sensor: gyroscope, accelerometer, magnetic, light, pressure, proximity, gravity, linear_acceleration, rotation.",
        {"sensor": {"type": "string", "enum": ["all","gyroscope","accelerometer","magnetic","light","pressure","proximity","gravity","linear_acceleration","rotation"], "description": "Sensor type or all"}},
        ["sensor"],
      ),
      _def(
        "ssh_execute",
        "Execute a command on a remote server via SSH. Supports password and private key auth. Provide host, port, username, command, and either password or private_key/private_key_path.",
        {
          "host": {"type": "string", "description": "SSH server hostname/IP"},
          "port": {"type": "string", "description": "SSH port"},
          "username": {"type": "string", "description": "SSH username"},
          "password": {"type": "string", "description": "SSH password (omit if using key)"},
          "private_key": {"type": "string", "description": "SSH private key content (PEM)"},
          "private_key_path": {"type": "string", "description": "Path to private key file on device"},
          "passphrase": {"type": "string", "description": "Passphrase for encrypted private key (optional)"},
          "command": {"type": "string", "description": "Command to execute"},
        },
        ["host","port","username","command"],
      ),
      _def(
        "ssh_scp",
        "Transfer files via SCP. Supports upload (local->remote) and download (remote->local). Same SSH auth params as ssh_execute.",
        {
          "action": {"type": "string", "enum": ["upload","download"], "description": "upload or download"},
          "host": {"type": "string", "description": "SSH server hostname/IP"},
          "port": {"type": "string", "description": "SSH port"},
          "username": {"type": "string", "description": "SSH username"},
          "password": {"type": "string", "description": "SSH password (omit if using key)"},
          "private_key": {"type": "string", "description": "SSH private key content (PEM)"},
          "private_key_path": {"type": "string", "description": "Path to private key file on device"},
          "passphrase": {"type": "string", "description": "Passphrase for encrypted private key (optional)"},
          "local_path": {"type": "string", "description": "Local file path"},
          "remote_path": {"type": "string", "description": "Remote file path"},
        },
        ["action","host","port","username","local_path","remote_path"],
      ),
      _def(
        "send_notification",
        "Send an Android notification to the status bar. Use for reminders, alerts, and status updates. Will request notification permission if needed.",
        {
          "title": {"type": "string", "description": "Notification title"},
          "content": {"type": "string", "description": "Notification body text"},
        },
        ["title","content"],
      ),
      _def(
        "play_sound",
        "Play a sound. Two modes: tone (frequency-based beep) or audio_url (play audio from URL or local file:///path). Use tone for simple alerts, audio_url for TTS, music or local audio files.",
        {
          "mode": {"type": "string", "enum": ["tone","audio_url"], "description": "tone=beep, audio_url=play URL (http/https/file:///path)"},
          "frequency": {"type": "integer", "description": "Frequency in Hz for tone mode (200-3000)"},
          "duration_ms": {"type": "integer", "description": "Duration in ms for tone mode (50-5000)"},
          "volume": {"type": "number", "description": "Volume 0.0-1.0"},
          "url": {"type": "string", "description": "Audio URL for audio_url mode. Supports http/https remote URLs and file:/// local paths, e.g. file:///data/user/0/com.psyche.kelivo/recording.wav"},
          "stream_type": {"type": "string", "enum": ["notification","alarm","music","ring"], "description": "Audio stream type (default notification)"},
        },
        ["mode"],
      ),
      _def(
        "execute_python",
        "Execute Python code on-device via embedded Python 3.13. Supports: code (run snippet), script (run script file), pip (install packages), info (query environment).\n"
            "Example: execute_python with action=code, code=\"print(hello)\"\n"
            "Or action=script, path=\"/data/user/0/com.psyche.kelivo/script.py\" to run a local Python script.\n"
            "Or action=pip, packages=\"requests\" to install a package.",
        {
          "action": {"type": "string", "enum": ["code","pip","info","script"], "description": "code=run code, script=run script file, pip=install packages, info=query env"},
          "code": {"type": "string", "description": "Python code to execute (for action=code)"},
          "path": {"type": "string", "description": "Python script file path (for action=script), e.g. /data/user/0/com.psyche.kelivo/script.py"},
          "packages": {"type": "string", "description": "Package names to pip install, space-separated (for action=pip)"},
        },
        ["action"],
      ),
      _def(
        "wait",
        "Wait for a specified duration in milliseconds, useful for pausing AI execution when waiting for other tasks to complete.",
        {
          "duration_ms": {"type": "integer", "description": "Wait duration in milliseconds, range 1000–300000 (1s–5min)"},
        },
        ["duration_ms"],
      ),
      _def(
        "baidu_search",
        "Search the web using Baidu search engine. Returns title, url, snippet for each result.",
        {"query": {"type": "string", "description": "The search query"}},
        ["query"],
      ),
      _def(
        "baidu_baike",
        "Look up a Baidu Baike entry. Returns title, summary, and url.",
        {"query": {"type": "string", "description": "The baike entry name"}},
        ["query"],
      ),

    ];
  }

  static Map<String, dynamic> _def(String name, String desc, Map<String, dynamic> props, [List<String>? req]) {
    return {
      "type": "function",
      "function": {
        "name": name,
        "description": desc,
        "parameters": {
          "type": "object",
          "properties": props,
          if (req != null && req.isNotEmpty) "required": req,
        },
      },
    };
  }

  /// Execute a device tool call. Returns JSON string result.
  static Future<String> execute(String name, Map<String, dynamic> args) async {
    try {
      if (name == "baidu_search") {
        return await BaiduQianfanService.search(args["query"] as String? ?? "");
      }
      if (name == "baidu_baike") {
        return await BaiduQianfanService.baike(args["query"] as String? ?? "");
      }

      // Request permissions before calling native tools
      if (name == "send_notification") {
        try {
          await NotificationService.ensureAndroidNotificationsPermission();
        } catch (_) {}
      }
      if (name == "get_gps_location") {
        try {
          final loc = Permission.location;
          if (!await loc.isGranted) {
            await loc.request();
          }
        } catch (_) {}
      }

      if (name == "execute_python") {
        final raw = await _pythonChannel.invokeMethod("execute", args).timeout(
          const Duration(seconds: 120),
          onTimeout: () => jsonEncode({"error": "Python execution timed out after 120 seconds"}),
        );
        if (raw is String) return raw;
        return jsonEncode({"error": "unexpected response type"});
      }
      // All other tools go through app.tools channel
      final result = await _toolsChannel.invokeMethod(name, args).timeout(
        const Duration(seconds: 60),
        onTimeout: () => jsonEncode({"error": "Tool '$name' timed out after 60 seconds"}),
      );
      if (result is String) return result;
      return jsonEncode({"success": true, "result": result});
    } catch (e) {
      return jsonEncode({"error": e.toString()});
    }
  }
}
