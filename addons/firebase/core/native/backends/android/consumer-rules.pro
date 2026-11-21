-keepattributes RuntimeVisibleAnnotations,RuntimeInvisibleAnnotations
-keep class dev.autoload.firebase.core.FirebaseCorePlugin { public <init>(org.godotengine.godot.Godot); }
-keepclassmembers class dev.autoload.firebase.core.FirebaseCorePlugin {
    @org.godotengine.godot.plugin.UsedByGodot <methods>;
}
