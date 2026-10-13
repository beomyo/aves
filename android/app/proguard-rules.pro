# cf https://developer.android.com/topic/performance/app-optimization/add-keep-rules

# e.g. com.drew.metadata.exif.ExifSubIFDDirectory
-keep class com.drew.metadata.**{ *; }

-keep class org.beyka.tiffbitmapfactory.**{ *; }

-keep class org.mp4parser.**{ *; }

# libVLC (flutter_vlc_player): the Java layer is reached from native code
-keep class org.videolan.libvlc.**{ *; }
-keep class software.solid.fluttervlcplayer.**{ *; }
-dontwarn org.videolan.libvlc.**

# referenced from: com.google.crypto.tink
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
