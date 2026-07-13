package com.psyche.kelivo

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import androidx.core.content.ContextCompat
import com.google.gson.Gson

/**
 * GPS 定位工具
 * 获取 Android 设备的当前位置信息（经纬度）
 */
class GPSTool(private val context: Context) : Tool {

    private val gson = Gson()

    override val name: String = "get_gps_location"

    override val description: String =
        "获取 Android 设备的当前 GPS 位置信息，包括经度、纬度、精度、海拔等。需要已授予定位权限"

    override val parameters: Map<String, Any> = mapOf(
        "type" to "object",
        "properties" to emptyMap<String, Any>(),
        "required" to emptyList<String>()
    )

    override suspend fun execute(args: Map<String, Any>): String {
        // 检查权限
        val hasFine = ContextCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasFine && !hasCoarse) {
            return gson.toJson(mapOf(
                "error" to true,
                "message" to "缺少定位权限（ACCESS_FINE_LOCATION）。请在系统设置中授予定位权限后重试",
                "hint" to "需要到 设置 → 应用 → Android Agent → 权限 → 位置 中开启"
            ))
        }

        return try {
            val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager

            // 获取所有可用的位置提供者（GPS优先）
            val providers = listOf(
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER,
                LocationManager.PASSIVE_PROVIDER
            )

            var bestLocation: android.location.Location? = null

            for (provider in providers) {
                try {
                    val location = locationManager.getLastKnownLocation(provider)
                    if (location != null) {
                        if (bestLocation == null || location.accuracy < bestLocation.accuracy) {
                            bestLocation = location
                        }
                    }
                } catch (_: SecurityException) {
                    // 某个 provider 权限不足，跳过
                } catch (_: IllegalArgumentException) {
                    // provider 不存在，跳过
                }
            }

            if (bestLocation == null) {
                return gson.toJson(mapOf(
                    "error" to true,
                    "message" to "无法获取位置信息。请确保已开启 GPS 或网络定位",
                    "hint" to "下拉通知栏开启 GPS，或在室外空旷处重试"
                ))
            }

            val loc = bestLocation!!
            gson.toJson(mapOf(
                "success" to true,
                "latitude" to loc.latitude,
                "longitude" to loc.longitude,
                "accuracy" to "${loc.accuracy}米",
                "altitude" to "${loc.altitude}米",
                "bearing" to "${loc.bearing}°",
                "speed" to "${loc.speed}米/秒",
                "provider" to loc.provider,
                "time" to loc.time
            ))

        } catch (e: SecurityException) {
            gson.toJson(mapOf(
                "error" to true,
                "message" to "定位权限被拒绝: ${e.message}"
            ))
        } catch (e: Exception) {
            gson.toJson(mapOf(
                "error" to true,
                "message" to "获取位置失败: ${e.message}"
            ))
        }
    }
}
