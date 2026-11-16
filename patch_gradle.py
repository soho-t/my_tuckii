import re, glob

PACKAGE_NAME = "io.github.sohot.mytuckii"

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

# 3. 更新 app/build.gradle：替換 namespace、applicationId、minSdk=24、NDK 與正式簽署配置
for f in glob.glob("android/app/build.gradle*"):
    s = open(f, encoding="utf-8").read()
    s = re.sub(r'namespace\s*=?\s*["\'][^"\']+["\']', f'namespace = "{PACKAGE_NAME}"', s)
    s = re.sub(r'applicationId\s*=?\s*["\'][^"\']+["\']', f'applicationId = "{PACKAGE_NAME}"', s)
    s = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', s)
    s = re.sub(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 24', s)
    s = re.sub(r'ndkVersion\s*=?\s*flutter\.ndkVersion', 'ndkVersion = "25.1.8937393"', s)
    s = s.replace('JavaVersion.VERSION_1_8', 'JavaVersion.VERSION_17')
    s = re.sub(r'jvmTarget\s*=\s*["\']1\.8["\']', 'jvmTarget = "17"', s)

    # 注入 key.properties 讀取與 release signingConfig
    signing_header = '''
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}
'''
    s = signing_header + "\n" + s

    signing_block = '''
    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword keystoreProperties['storePassword']
        }
    }
    buildTypes {
        release {
            signingConfig signingConfigs.release
'''
    s = re.sub(
        r'buildTypes\s*\{\s*release\s*\{\s*signingConfig\s+signingConfigs\.debug',
        signing_block.strip(),
        s
    )
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

print("Package ID io.github.sohot.mytuckii & Release Signing patched successfully!")
