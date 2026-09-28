// Root build for the TokenX libraries.
//
//   tokenx-core     pure Kotlin/JVM: catalog, profiles, providers over HTTP, repositories, server, client
//   tokenx-android  Android: SQLite database adapter and the Keystore cipher
plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
}

allprojects {
    group = "com.bclnet.tokenx"
    version = "1.0.0"
}
