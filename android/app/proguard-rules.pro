# shared_preferences_android 2.5+ 改用 JNI（package:jni）直接调用 Kotlin 类，
# R8 混淆类/方法名后 JNI 查不到，运行期报
# NoSuchMethodError: no non-static method
#   "Lio/flutter/plugins/sharedpreferences/SharedPreferencesApiRegistrar;.getAll(...)"
# 结果就是所有 SharedPreferences 读写失败（配置/MCP/开关全无）。
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-dontwarn io.flutter.plugins.sharedpreferences.**

-dontwarn com.gemalto.jp2.**
-dontwarn com.tom_roush.pdfbox.filter.JPXFilter

# JSch loads its JCE providers (com.jcraft.jsch.jce.*) via reflection.
# Without these rules R8 strips them -> ClassNotFoundException e.g. com.jcraft.jsch.jce.Random
-dontwarn com.jcraft.jsch.**
-keep class com.jcraft.jsch.** { *; }
-keep class com.github.mwiede.jsch.** { *; }
