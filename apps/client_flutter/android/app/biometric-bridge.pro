# The separately installed device test invokes this narrow app/Flutter bridge ABI.
-keep,includedescriptorclasses class com.example.securemesh_client.ProfileBiometrics {
    public <init>(android.content.Context);
    public void handle(io.flutter.plugin.common.MethodCall, io.flutter.plugin.common.MethodChannel$Result);
}
-keepclassmembers class io.flutter.plugin.common.MethodCall {
    public <init>(java.lang.String, java.lang.Object);
}
-keepclassmembers interface io.flutter.plugin.common.MethodChannel$Result { *; }
