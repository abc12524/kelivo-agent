package com.psyche.kelivo

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import com.google.gson.Gson
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * 传感器工具
 * 获取 Android 设备的陀螺仪、加速度计、磁力计等传感器数据
 */
class SensorTool(private val context: Context) : Tool {

    private val gson = Gson()

    override val name: String = "get_sensor_data"

    override val description: String =
        "获取 Android 设备的传感器数据，包括陀螺仪（角速度）、加速度计、磁力计（磁场/指南针）、环境光、气压、温度、湿度等"

    override val parameters: Map<String, Any> = mapOf(
        "type" to "object",
        "properties" to mapOf(
            "sensor" to mapOf(
                "type" to "string",
                "enum" to listOf("all", "gyroscope", "accelerometer", "magnetic", "light", "pressure", "proximity", "gravity", "linear_acceleration", "rotation"),
                "description" to "要读取的传感器类型。all=所有可用传感器"
            )
        ),
        "required" to listOf("sensor")
    )

    override suspend fun execute(args: Map<String, Any>): String {
        val sensorType = args["sensor"] as? String ?: "all"

        val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            ?: return gson.toJson(mapOf("error" to true, "message" to "设备不支持 SensorManager"))

        if (sensorType == "all") {
            return getAllSensors(sensorManager)
        }

        val type = mapSensorType(sensorType) ?: return gson.toJson(mapOf(
            "error" to true, "message" to "不支持的传感器类型: $sensorType"
        ))

        return readSensorOnce(sensorManager, type, sensorType)
    }

    /**
     * 列出所有可用传感器
     */
    private fun getAllSensors(sensorManager: SensorManager): String {
        val sensors = sensorManager.getSensorList(Sensor.TYPE_ALL)
        if (sensors.isEmpty()) {
            return gson.toJson(mapOf("error" to true, "message" to "设备上未发现任何传感器"))
        }

        val result = sensors.map { s ->
            mapOf(
                "name" to s.name,
                "type" to sensorTypeName(s.type),
                "vendor" to s.vendor,
                "version" to s.version,
                "power" to "${s.power} mA",
                "resolution" to "${s.resolution}",
                "max_range" to "${s.maximumRange}",
                "min_delay" to "${s.minDelay} μs"
            )
        }

        return gson.toJson(mapOf(
            "success" to true,
            "sensor_count" to result.size,
            "sensors" to result
        ))
    }

    /**
     * 读取单个传感器的瞬时值
     */
    private suspend fun readSensorOnce(
        sensorManager: SensorManager,
        sensorType: Int,
        typeName: String
    ): String = suspendCancellableCoroutine { continuation ->
        val sensor = sensorManager.getDefaultSensor(sensorType)
        if (sensor == null) {
            continuation.resume(gson.toJson(mapOf(
                "error" to true,
                "message" to "设备上未找到 ${typeName} 传感器"
            )))
            return@suspendCancellableCoroutine
        }

        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                sensorManager.unregisterListener(this)

                val values = event.values.mapIndexed { i, v ->
                    when (sensorType) {
                        Sensor.TYPE_GYROSCOPE -> {
                            listOf("x (rad/s)", "y (rad/s)", "z (rad/s)")
                        }
                        Sensor.TYPE_ACCELEROMETER -> {
                            listOf("x (m/s²)", "y (m/s²)", "z (m/s²)")
                        }
                        Sensor.TYPE_MAGNETIC_FIELD -> {
                            listOf("x (μT)", "y (μT)", "z (μT)")
                        }
                        Sensor.TYPE_GRAVITY -> {
                            listOf("x (m/s²)", "y (m/s²)", "z (m/s²)")
                        }
                        Sensor.TYPE_LINEAR_ACCELERATION -> {
                            listOf("x (m/s²)", "y (m/s²)", "z (m/s²)")
                        }
                        Sensor.TYPE_ROTATION_VECTOR -> {
                            listOf("x", "y", "z", "cos(θ/2)", "accuracy")
                        }
                        else -> event.values.indices.map { "value_$it" }
                    }.getOrElse(i) { "value_$i" }
                }.let { labels ->
                    event.values.mapIndexed { i, v ->
                        mapOf(
                            "axis" to labels.getOrElse(i) { "value_$i" },
                            "value" to String.format("%.4f", v)
                        )
                    }
                }

                val extras = mutableMapOf<String, Any>()
                extras["sensor"] = sensor.name
                extras["type"] = typeName
                extras["accuracy"] = sensorAccuracyName(event.accuracy)
                extras["timestamp"] = event.timestamp
                extras["values"] = values

                continuation.resume(gson.toJson(mapOf("success" to true) + extras))
            }

            override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
        }

        // 注册监听，等待一次数据更新
        sensorManager.registerListener(
            listener, sensor,
            SensorManager.SENSOR_DELAY_FASTEST
        )

        continuation.invokeOnCancellation {
            sensorManager.unregisterListener(listener)
        }
    }

    private fun mapSensorType(name: String): Int? = when (name) {
        "gyroscope" -> Sensor.TYPE_GYROSCOPE
        "accelerometer" -> Sensor.TYPE_ACCELEROMETER
        "magnetic" -> Sensor.TYPE_MAGNETIC_FIELD
        "light" -> Sensor.TYPE_LIGHT
        "pressure" -> Sensor.TYPE_PRESSURE
        "proximity" -> Sensor.TYPE_PROXIMITY
        "gravity" -> Sensor.TYPE_GRAVITY
        "linear_acceleration" -> Sensor.TYPE_LINEAR_ACCELERATION
        "rotation" -> Sensor.TYPE_ROTATION_VECTOR
        else -> null
    }

    private fun sensorTypeName(type: Int): String = when (type) {
        Sensor.TYPE_ACCELEROMETER -> "加速度计"
        Sensor.TYPE_MAGNETIC_FIELD -> "磁力计"
        Sensor.TYPE_GYROSCOPE -> "陀螺仪"
        Sensor.TYPE_LIGHT -> "环境光"
        Sensor.TYPE_PRESSURE -> "气压计"
        Sensor.TYPE_PROXIMITY -> "距离传感器"
        Sensor.TYPE_GRAVITY -> "重力"
        Sensor.TYPE_LINEAR_ACCELERATION -> "线性加速度"
        Sensor.TYPE_ROTATION_VECTOR -> "旋转向量"
        Sensor.TYPE_RELATIVE_HUMIDITY -> "湿度"
        Sensor.TYPE_AMBIENT_TEMPERATURE -> "温度"
        Sensor.TYPE_STEP_COUNTER -> "计步器"
        Sensor.TYPE_STEP_DETECTOR -> "步数检测"
        Sensor.TYPE_HEART_RATE -> "心率"
        else -> "其他($type)"
    }

    private fun sensorAccuracyName(accuracy: Int): String = when (accuracy) {
        SensorManager.SENSOR_STATUS_ACCURACY_HIGH -> "高"
        SensorManager.SENSOR_STATUS_ACCURACY_MEDIUM -> "中"
        SensorManager.SENSOR_STATUS_ACCURACY_LOW -> "低"
        SensorManager.SENSOR_STATUS_UNRELIABLE -> "不可靠"
        else -> "未知"
    }
}
