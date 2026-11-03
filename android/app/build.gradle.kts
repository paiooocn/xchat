import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.yimo.xchat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        // 允许在 defaultConfig 里用 resValue() 定义字符串资源（启动器名字 app_name）。
        resValues = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.yimo.xchat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ---- 启动器名字（图标下面那行字）----
        //
        // 默认 "XChat"；改名版（SixChat）由构建期注入：
        //   flutter build apk --release --dart-define=APP_BRAND_NAME=SixChat
        // flutter 会把每个 --dart-define 单独 base64 编码后用 "," 连接，传给
        // gradle 的 `-Pdart-defines=<base64>`，这里解出来。
        //
        // 注意：只改显示名，applicationId（com.yimo.xchat）不变 —— 改名版与
        // 正式版是同一个应用（安装时互相覆盖，数据目录共用）。
        val dartDefines = providers.gradleProperty("dart-defines").orNull.orEmpty()
        val appName = dartDefines
            .split(',')
            .mapNotNull { item ->
                runCatching { String(Base64.getDecoder().decode(item)) }.getOrNull()
            }
            .firstOrNull { it.startsWith("APP_BRAND_NAME=") }
            ?.substringAfter('=')
            ?.takeIf { it.isNotBlank() }
            ?: "XChat"
        resValue("string", "app_name", appName)
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
