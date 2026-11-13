import re, glob

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

# 3. 設定 app/build.gradle 的 minSdk = 24、ndkVersion 與 JVM 17
for f in glob.glob("android/app/build.gradle*"):
    s = open(f, encoding="utf-8").read()
    s = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', s)
    s = re.sub(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 24', s)
    s = re.sub(r'ndkVersion\s*=?\s*flutter\.ndkVersion', 'ndkVersion = "25.1.8937393"', s)
    s = s.replace('JavaVersion.VERSION_1_8', 'JavaVersion.VERSION_17')
    s = re.sub(r'jvmTarget\s*=\s*["\']1\.8["\']', 'jvmTarget = "17"', s)
    open(f, "w", encoding="utf-8").write(s)

# 4. 強制所有第三方套件 (如 receive_sharing_intent) 統一使用 JVM 17，解決 1.8 與 17 衝突
root_gradle = "android/build.gradle"
try:
    r = open(root_gradle, encoding="utf-8").read()
    jvm_fix = """
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
"""
    open(root_gradle, "w", encoding="utf-8").write(r + "\n" + jvm_fix)
except FileNotFoundError:
    pass

print("All Gradle, NDK & JVM 17 targets aligned successfully!")