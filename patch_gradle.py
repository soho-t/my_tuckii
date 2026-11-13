import re, glob

# 1. 升級 Kotlin 至 2.1.0，並將 Android Gradle Plugin (AGP) 升級至 8.3.2
for f in glob.glob("android/settings.gradle*"):
    s = open(f, encoding="utf-8").read()
    s = re.sub(r'(id\s+["\']org\.jetbrains\.kotlin\.android["\']\s+version\s+["\'])[^"\']+', r'\g<1>2.1.0', s)
    s = re.sub(r'(id\s+["\']com\.android\.application["\']\s+version\s+["\'])[^"\']+', r'\g<1>8.3.2', s)
    open(f, "w", encoding="utf-8").write(s)

# 2. 升級 Gradle Wrapper 版本至 8.4 以匹配 AGP 8.3.2
wrapper_file = "android/gradle/wrapper/gradle-wrapper.properties"
try:
    w = open(wrapper_file, encoding="utf-8").read()
    w = re.sub(r'gradle-[0-9.]+-all\.zip', 'gradle-8.4-all.zip', w)
    open(wrapper_file, "w", encoding="utf-8").write(w)
except FileNotFoundError:
    pass

# 3. 設定 minSdk = 24
for f in glob.glob("android/app/build.gradle*"):
    s = open(f, encoding="utf-8").read()
    s = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', s)
    s = re.sub(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 24', s)
    open(f, "w", encoding="utf-8").write(s)

print("AGP 8.3.2, Gradle 8.4 & Kotlin 2.1.0 patched successfully!")