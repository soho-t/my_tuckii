import re, glob

for f in glob.glob("android/settings.gradle*"):
    s = open(f, encoding="utf-8").read()
    s = re.sub(r'(id\s+["\']org\.jetbrains\.kotlin\.android["\']\s+version\s+["\'])[^"\']+', r'\g<1>2.1.0', s)
    open(f, "w", encoding="utf-8").write(s)

for f in glob.glob("android/app/build.gradle*"):
    s = open(f, encoding="utf-8").read()
    s = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 24', s)
    s = re.sub(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 24', s)
    open(f, "w", encoding="utf-8").write(s)

print("Gradle patched successfully!")
