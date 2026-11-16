import os, re, glob, shutil

PACKAGE_NAME = "io.github.sohot.mytuckii"
PACKAGE_PATH = "android/app/src/main/kotlin/io/github/sohot/mytuckii"

# 0. 修正 MainActivity.kt 實體資料夾路徑與 package 宣告
kotlin_root = "android/app/src/main/kotlin"
if os.path.exists(kotlin_root):
    shutil.rmtree(kotlin_root)
os.makedirs(PACKAGE_PATH, exist_ok=True)
with open(f"{PACKAGE_PATH}/MainActivity.kt", "w", encoding="utf-8") as f:
    f.write(f"""package {PACKAGE_NAME}

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity()
""")

# 1. 升級 Kotlin 至 2.1.0 與 Android Gradle Plugin (AGP) 至 8.3.2
for f in glob.glob("android/settings.gradle*"):
    s = open(f, encoding="utf-8").read()
    s = re.sub(r'(id\s+["\']org\.jetbrains\.kotlin\.android["\']\s+version\s+["\'])[^"\']+', r'\g<1>2.1.0', s)
    s = re.sub(r'(id\s+["\']com\.android\.application["\']\s+version\s+["\'])[^"\']+', r'\g<1>8.3.2', s)
    open(f, "w", encoding="utf-8").write(s)

# 2. 升級 Gradle Wrapper 至 8.4
wrapper_file = "android/gradle/wrapper/gradle-wrapper.properties"
try:
    w = open(wrapper_file, encoding="utf-8").read()
    w = re.sub(r'gradle-[0-9.]+-all\.zip', 'gradle-8.4-all.zip', w)
    open(wrapper_file, "w", encoding="utf-8").write(w)
except FileNotFoundError:
    pass

# 3. 更新 app/build.gradle：注入 signingConfigs.release 並強制替換 signingConfigs.debug
for f in glob.glob("android/app/build.gradle*"):
    s = open(f, encoding="utf-8").read()
    s = re.sub(r'namespace\s*=?\s*["\'][^"\']+["\']', f'namespace = "{PACKAGE_NAME}"', s)
    s = re.sub(r'applicationId\s*=?\s*["\'][^"\']+["\']', f'applicationId = "{PACKAGE_NAME}"', s)
    s = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', s)
    s = re.sub(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 24', s)
    s = re.sub(r'ndkVersion\s*=?\s*flutter\.ndkVersion', 'ndkVersion = "25.1.8937393"', s)
    s = s.replace('JavaVersion.VERSION_1_8', 'JavaVersion.VERSION_17')
    s = re.sub(r'jvmTarget\s*=\s*["\']1\.8["\']', 'jvmTarget = "17"', s)

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
    s = re.sub(r'signingConfig\s*=?\s*signingConfigs\.debug', 'signingConfig = signingConfigs.release', s)
    open(f, "w", encoding="utf-8").write(s)

# 4. 強制所有第三方套件統一使用 JVM 17
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
            jvmTarget = "17"
        }
    }
}
'''
    open(root_gradle, "w", encoding="utf-8").write(r + "\n" + jvm_fix)
except FileNotFoundError:
    pass

print("Release signingConfig forced successfully!")