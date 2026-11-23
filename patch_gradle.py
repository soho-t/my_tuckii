import os, re, glob, shutil

PACKAGE_NAME = "io.github.sohot.mytuckii"
PACKAGE_PATH = "android/app/src/main/kotlin/io/github/sohot/mytuckii"

# 0. 生成 MainActivity.kt 與 QuickSaveTileService.kt
kotlin_root = "android/app/src/main/kotlin"
if os.path.exists(kotlin_root):
    shutil.rmtree(kotlin_root)
os.makedirs(PACKAGE_PATH, exist_ok=True)

with open(f"{PACKAGE_PATH}/MainActivity.kt", "w", encoding="utf-8") as f:
    f.write(f"""package {PACKAGE_NAME}

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {{
    companion object {{
        const val CHANNEL = "io.github.sohot.mytuckii/quick_save"
        const val ACTION_QUICK_SAVE = "io.github.sohot.mytuckii.ACTION_QUICK_SAVE"
    }}

    private var quickSaveChannel: MethodChannel? = null
    private var pendingQuickSave: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {{
        super.onCreate(savedInstanceState)
        if (intent?.action == ACTION_QUICK_SAVE) {{
            pendingQuickSave = true
        }}
    }}

    override fun onNewIntent(intent: Intent) {{
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == ACTION_QUICK_SAVE) {{
            val ch = quickSaveChannel
            if (ch != null) {{
                ch.invokeMethod("onQuickSaveTrigger", null)
            }} else {{
                pendingQuickSave = true
            }}
        }}
    }}

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        quickSaveChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        quickSaveChannel?.setMethodCallHandler {{ call, result ->
            when (call.method) {{
                "consumePendingQuickSave" -> {{
                    val value = pendingQuickSave
                    pendingQuickSave = false
                    result.success(value)
                }}
                "showToastAndMinimize" -> {{
                    val message = call.argument<String>("message") ?: ""
                    val minimize = call.argument<Boolean>("minimize") ?: false
                    if (message.isNotEmpty()) {{
                        Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
                    }}
                    if (minimize) {{
                        moveTaskToBack(true)
                    }}
                    result.success(null)
                }}
                "requestAddTile" -> {{
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {{
                        try {{
                            val statusBarManager = getSystemService(StatusBarManager::class.java)
                            statusBarManager.requestAddTileService(
                                ComponentName(this, QuickSaveTileService::class.java),
                                "存進隨手存",
                                Icon.createWithResource(this, R.mipmap.ic_launcher),
                                mainExecutor
                            ) {{ status ->
                                // 系統會自動顯示加入結果
                            }}
                            result.success("requested")
                        }} catch (e: Exception) {{
                            result.success("manual")
                        }}
                    }} else {{
                        result.success("manual")
                    }}
                }}
                else -> result.notImplemented()
            }}
        }}
    }}
}}
""")

with open(f"{PACKAGE_PATH}/QuickSaveTileService.kt", "w", encoding="utf-8") as f:
    f.write(f"""package {PACKAGE_NAME}

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class QuickSaveTileService : TileService() {{
    override fun onStartListening() {{
        super.onStartListening()
        qsTile?.let {{ tile ->
            tile.state = Tile.STATE_INACTIVE
            tile.label = "存進隨手存"
            tile.updateTile()
        }}
    }}

    override fun onClick() {{
        super.onClick()
        val intent = Intent(this, MainActivity::class.java).apply {{
            action = MainActivity.ACTION_QUICK_SAVE
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }}

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {{
            val pendingIntent = PendingIntent.getActivity(
                this,
                1001,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            startActivityAndCollapse(pendingIntent)
        }} else {{
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }}
    }}
}}
""")

# 1. 設定最穩定的黃金組合：Kotlin 1.9.24 + AGP 8.3.2
for f in glob.glob("android/settings.gradle*"):
    s = open(f, encoding="utf-8").read()
    s = re.sub(r'(id\s+["\']org\.jetbrains\.kotlin\.android["\']\s+version\s+["\'])[^"\']+', r'\g<1>1.9.24', s)
    s = re.sub(r'(id\s+["\']com\.android\.application["\']\s+version\s+["\'])[^"\']+', r'\g<1>8.3.2', s)
    open(f, "w", encoding="utf-8").write(s)

# 2. 設定 Gradle Wrapper 為 8.4
wrapper_file = "android/gradle/wrapper/gradle-wrapper.properties"
try:
    w = open(wrapper_file, encoding="utf-8").read()
    w = re.sub(r'gradle-[0-9.]+-all\.zip', 'gradle-8.4-all.zip', w)
    open(wrapper_file, "w", encoding="utf-8").write(w)
except FileNotFoundError:
    pass

# 3. 加入網路逾時延長設定
gradle_props = "android/gradle.properties"
try:
    gp = open(gradle_props, encoding="utf-8").read() if os.path.exists(gradle_props) else ""
    net_timeouts = """
org.gradle.internal.http.connectionTimeout=120000
org.gradle.internal.http.socketTimeout=120000
org.gradle.HcMaxRetries=5
"""
    if "connectionTimeout" not in gp:
        open(gradle_props, "w", encoding="utf-8").write(gp + "\n" + net_timeouts.strip() + "\n")
except Exception:
    pass

# 4. 更新 app/build.gradle：升級 compileSdk 35、開啟 coreLibraryDesugaring、注入 signingConfigs.release
for f in glob.glob("android/app/build.gradle*"):
    s = open(f, encoding="utf-8").read()
    s = re.sub(r'namespace\s*=?\s*["\'][^"\']+["\']', f'namespace = "{PACKAGE_NAME}"', s)
    s = re.sub(r'applicationId\s*=?\s*["\'][^"\']+["\']', f'applicationId = "{PACKAGE_NAME}"', s)
    s = re.sub(r'compileSdk\s*=\s*flutter\.compileSdkVersion', 'compileSdk = 35', s)
    s = re.sub(r'compileSdkVersion\s+flutter\.compileSdkVersion', 'compileSdkVersion 35', s)
    s = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', s)
    s = re.sub(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 24', s)
    s = re.sub(r'ndkVersion\s*=?\s*flutter\.ndkVersion', 'ndkVersion = "25.1.8937393"', s)
    s = s.replace('JavaVersion.VERSION_1_8', 'JavaVersion.VERSION_17')
    s = re.sub(r'jvmTarget\s*=\s*["\']1\.8["\']', 'jvmTarget = "17"', s)

    if "coreLibraryDesugaringEnabled" not in s:
        s = re.sub(
            r'compileOptions\s*\{',
            'compileOptions {\n        coreLibraryDesugaringEnabled true',
            s,
            count=1
        )
    if "desugar_jdk_libs" not in s:
        s = s + '\ndependencies {\n    coreLibraryDesugaring "com.android.tools:desugar_jdk_libs:2.0.4"\n}\n'

    signing_setup = '''
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword keystoreProperties['storePassword']
        }
    }'''
    s = re.sub(r'android\s*\{', signing_setup.strip(), s, count=1)
    release_config = '''signingConfig = signingConfigs.release
            minifyEnabled false
            shrinkResources false'''
    s = re.sub(r'signingConfig\s*=?\s*signingConfigs\.debug', release_config, s)
    open(f, "w", encoding="utf-8").write(s)

# 5. 在 evaluationDependsOn 之前注入子專案規則
root_gradle = "android/build.gradle"
try:
    r = open(root_gradle, encoding="utf-8").read()
    jvm_fix = '''
subprojects {
    plugins.withId("com.android.library") {
        android {
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        }
    }
    tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile).configureEach {
        kotlinOptions {
            if (project.hasProperty("android") && project.android.compileOptions.targetCompatibility != null) {
                jvmTarget = project.android.compileOptions.targetCompatibility.toString()
            } else {
                jvmTarget = "17"
            }
        }
    }
}
'''
    target_anchor = 'subprojects {\n    project.evaluationDependsOn(":app")\n}'
    if target_anchor in r:
        r = r.replace(target_anchor, jvm_fix + "\n" + target_anchor)
    else:
        r = r + "\n" + jvm_fix
    open(root_gradle, "w", encoding="utf-8").write(r)
except FileNotFoundError:
    pass

print("MainActivity, QuickSaveTileService, and Gradle config applied successfully!")