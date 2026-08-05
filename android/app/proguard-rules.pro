-dontwarn com.gemalto.jp2.**
-dontwarn com.tom_roush.pdfbox.filter.JPXFilter

# JSch loads its JCE providers (com.jcraft.jsch.jce.*) via reflection.
# Without these rules R8 strips them -> ClassNotFoundException e.g. com.jcraft.jsch.jce.Random
-dontwarn com.jcraft.jsch.**
-keep class com.jcraft.jsch.** { *; }
-keep class com.github.mwiede.jsch.** { *; }
