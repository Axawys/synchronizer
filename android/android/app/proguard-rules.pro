# ML Kit's barcode scanner, which is what reads the pairing QR code.
#
# The scanner plugin ships keep rules of its own, but they are written with a
# single star - `com.google.mlkit.*` matches one package level and nothing
# below it - so everything under com.google.mlkit.vision.* was still being
# renamed. What that looks like at runtime is a null pointer deep inside the
# library, reported as "Attempt to invoke virtual method 'a4.a a4.d.a(w3.b)' on
# a null object reference", and a camera view that stays black.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.libraries.barhopper.** { *; }
-keep class com.google.photos.** { *; }
-dontwarn com.google.mlkit.**

# CameraX, which the scanner drives, resolves parts of itself by name.
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**
