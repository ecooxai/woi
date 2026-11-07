# The release APK is exercised by a separately compiled instrumentation APK.
# Keep the handwritten platform API stable across that APK boundary: R8 can
# otherwise remove Kotlin object INSTANCE fields before tests apply its mapping.
-keep class dev.woi.woi.** { *; }

# Test bytecode shares the target APK's Kotlin runtime. Keep its public API and
# facade class identities, including non-public facade parents with inherited
# public static methods. Keeping just TuplesKt fixes one crash but leaves the
# same failure for collection/text/IO/ref helpers called by compiled tests.
# Private implementation members remain eligible for normal R8 optimization.
-keep class kotlin.** {
    public *;
    protected *;
}

# Native instrumentation constructs calls and implements these callback types.
# They are the small external contract, not a keep rule for the Flutter engine.
-keep class io.flutter.plugin.common.MethodCall { *; }
-keep interface io.flutter.plugin.common.MethodChannel$Result { *; }
-keep interface io.flutter.plugin.common.EventChannel$EventSink { *; }
