-keepattributes RuntimeVisibleAnnotations,RuntimeInvisibleAnnotations
-keep class dev.autoload.firebase.analytics.FirebaseAnalyticsPlugin { public <init>(org.godotengine.godot.Godot); }
-keepclassmembers class dev.autoload.firebase.analytics.FirebaseAnalyticsPlugin {
    @org.godotengine.godot.plugin.UsedByGodot <methods>;
}
