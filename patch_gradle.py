import os, re, glob, shutil

PACKAGE_NAME = "io.github.sohot.mytuckii"
PACKAGE_PATH = "android/app/src/main/kotlin/io/github/sohot/mytuckii"

# 0. 生成 MainActivity.kt、QuickSaveTileService.kt、QuickSaveWidgetProvider.kt 與小工具 XML
kotlin_root = "android/app/src/main/kotlin"
if os.path.exists(kotlin_root):
    shutil.rmtree(kotlin_root)
os.makedirs(PACKAGE_PATH, exist_ok=True)

main_activity_kt = """package __PKG__

import android.app.StatusBarManager
import android.appwidget.AppWidgetManager
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "io.github.sohot.mytuckii/quick_save"
        const val ACTION_QUICK_SAVE = "io.github.sohot.mytuckii.ACTION_QUICK_SAVE"
    }

    private var quickSaveChannel: MethodChannel? = null
    private var pendingQuickSave: Boolean = false
    private var pendingQuickSaveText: String? = null
    private var dartReady: Boolean = false
    private var pendingClipResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent?.action == ACTION_QUICK_SAVE) {
            pendingQuickSave = true
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == ACTION_QUICK_SAVE) {
            pendingQuickSave = true
            if (hasWindowFocus()) {
                window.decorView.postDelayed({ dispatchQuickSaveIfReady() }, 120)
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            if (pendingQuickSave) {
                window.decorView.postDelayed({ dispatchQuickSaveIfReady() }, 150)
            }
            val clipResult = pendingClipResult
            if (clipResult != null) {
                pendingClipResult = null
                window.decorView.postDelayed({
                    try {
                        clipResult.success(readClipboardText())
                    } catch (_: Exception) {}
                }, 150)
            }
        }
    }

    private fun readClipboardText(): String {
        return try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = cm.primaryClip
            if (clip != null && clip.itemCount > 0) {
                clip.getItemAt(0).coerceToText(this)?.toString()?.trim() ?: ""
            } else {
                ""
            }
        } catch (e: Exception) {
            ""
        }
    }

    private fun dispatchQuickSaveIfReady() {
        if (!pendingQuickSave) return
        val text = readClipboardText()
        val ch = quickSaveChannel
        if (dartReady && ch != null) {
            pendingQuickSave = false
            pendingQuickSaveText = null
            ch.invokeMethod("onQuickSaveTrigger", text)
        } else {
            pendingQuickSaveText = text
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        quickSaveChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        quickSaveChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumePendingQuickSave" -> {
                    dartReady = true
                    if (pendingQuickSave) {
                        val cached = pendingQuickSaveText
                        if (cached != null) {
                            pendingQuickSave = false
                            pendingQuickSaveText = null
                            result.success(mapOf("pending" to true, "text" to cached))
                        } else if (hasWindowFocus()) {
                            pendingQuickSave = false
                            result.success(mapOf("pending" to true, "text" to readClipboardText()))
                        } else {
                            // 視窗尚未取得焦點，交由 onWindowFocusChanged 接手觸發
                            result.success(mapOf("pending" to false, "text" to ""))
                        }
                    } else {
                        result.success(mapOf("pending" to false, "text" to ""))
                    }
                }
                "readClipboardWhenFocused" -> {
                    if (hasWindowFocus()) {
                        window.decorView.postDelayed({
                            try {
                                result.success(readClipboardText())
                            } catch (_: Exception) {}
                        }, 120)
                    } else {
                        pendingClipResult = result
                        window.decorView.postDelayed({
                            val r = pendingClipResult
                            if (r != null) {
                                pendingClipResult = null
                                try {
                                    r.success(readClipboardText())
                                } catch (_: Exception) {}
                            }
                        }, 1200)
                    }
                }
                "showToastAndMinimize" -> {
                    val message = call.argument<String>("message") ?: ""
                    val minimize = call.argument<Boolean>("minimize") ?: false
                    if (message.isNotEmpty()) {
                        Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
                    }
                    if (minimize) {
                        moveTaskToBack(true)
                    }
                    result.success(null)
                }
                "requestAddTile" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        try {
                            val statusBarManager = getSystemService(StatusBarManager::class.java)
                            statusBarManager.requestAddTileService(
                                ComponentName(this, QuickSaveTileService::class.java),
                                "存進隨手存",
                                Icon.createWithResource(this, R.mipmap.ic_launcher),
                                mainExecutor
                            ) { _ -> }
                            result.success("requested")
                        } catch (e: Exception) {
                            result.success("manual")
                        }
                    } else {
                        result.success("manual")
                    }
                }
                "requestPinWidget" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try {
                            val appWidgetManager = AppWidgetManager.getInstance(this)
                            val provider = ComponentName(this, QuickSaveWidgetProvider::class.java)
                            if (appWidgetManager.isRequestPinAppWidgetSupported) {
                                appWidgetManager.requestPinAppWidget(provider, null, null)
                                result.success("requested")
                            } else {
                                result.success("manual")
                            }
                        } catch (e: Exception) {
                            result.success("manual")
                        }
                    } else {
                        result.success("manual")
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
""".replace("__PKG__", PACKAGE_NAME)

tile_service_kt = """package __PKG__

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class QuickSaveTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.let { tile ->
            tile.state = Tile.STATE_INACTIVE
            tile.label = "存進隨手存"
            tile.updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val intent = Intent(this, MainActivity::class.java).apply {
            action = MainActivity.ACTION_QUICK_SAVE
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pendingIntent = PendingIntent.getActivity(
                this,
                1001,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
""".replace("__PKG__", PACKAGE_NAME)

widget_provider_kt = """package __PKG__

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

class QuickSaveWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            val intent = Intent(context, MainActivity::class.java).apply {
                action = MainActivity.ACTION_QUICK_SAVE
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                2001,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val views = RemoteViews(context.packageName, R.layout.widget_quick_save)
            views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
""".replace("__PKG__", PACKAGE_NAME)

with open(f"{PACKAGE_PATH}/MainActivity.kt", "w", encoding="utf-8") as f:
    f.write(main_activity_kt)
with open(f"{PACKAGE_PATH}/QuickSaveTileService.kt", "w", encoding="utf-8") as f:
    f.write(tile_service_kt)
with open(f"{PACKAGE_PATH}/QuickSaveWidgetProvider.kt", "w", encoding="utf-8") as f:
    f.write(widget_provider_kt)

# 建立桌面小工具 XML 資源檔
res_root = "android/app/src/main/res"
os.makedirs(f"{res_root}/drawable", exist_ok=True)
os.makedirs(f"{res_root}/layout", exist_ok=True)
os.makedirs(f"{res_root}/xml", exist_ok=True)

with open(f"{res_root}/drawable/widget_quick_save_bg.xml", "w", encoding="utf-8") as f:
    f.write("""<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <solid android:color="#FAF7F2"/>
    <stroke android:width="1.5dp" android:color="#D6C7B2"/>
    <corners android:radius="20dp"/>
</shape>
""")

with open(f"{res_root}/layout/widget_quick_save.xml", "w", encoding="utf-8") as f:
    f.write("""<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/widget_root"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="@drawable/widget_quick_save_bg"
    android:gravity="center"
    android:orientation="horizontal"
    android:padding="10dp">

    <ImageView
        android:layout_width="26dp"
        android:layout_height="26dp"
        android:src="@mipmap/ic_launcher"
        android:contentDescription="隨手存" />

    <TextView
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:layout_marginStart="8dp"
        android:text="存剪貼簿"
        android:textColor="#3E2F20"
        android:textSize="14sp"
        android:textStyle="bold" />
</LinearLayout>
""")

with open(f"{res_root}/xml/widget_quick_save_info.xml", "w", encoding="utf-8") as f:
    f.write("""<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:minWidth="110dp"
    android:minHeight="40dp"
    android:targetCellWidth="2"
    android:targetCellHeight="1"
    android:updatePeriodMillis="0"
    android:initialLayout="@layout/widget_quick_save"
    android:resizeMode="horizontal|vertical"
    android:widgetCategory="home_screen" />
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

print("Focus-aware Clipboard, Widget, TileService, and Gradle config applied successfully!")