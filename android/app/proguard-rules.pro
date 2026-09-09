# R8 runs on release builds and strips generic type signatures. Gson resolves
# types at runtime through those signatures, so without these rules
# flutter_local_notifications throws "java.lang.RuntimeException: Missing type
# parameter." whenever it reads or writes its scheduled-notification store.
#
# That failure is not cosmetic: the plugin registers the alarm with AlarmManager
# and only then persists it, so the exception surfaced *after* an exact alarm had
# been set, driving the retry ladder to replace it with an inexact alarm that
# Doze then deferred. Scheduled orders silently stopped notifying on time, and
# nothing survived a reboot because the store could not be read back.

# Keep generic signatures and annotations for Gson's type resolution.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# flutter_local_notifications' serialised model classes.
-keep class com.dexterous.** { *; }
-dontwarn com.dexterous.**

# Gson itself.
-dontwarn sun.misc.**
-keep class com.google.gson.** { *; }
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}

# Anonymous TypeToken subclasses carry their type only in the generic signature.
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken
