// Root build for the TokenX libraries.
//
//   tokenx-core     pure Kotlin/JVM: catalog, profiles, providers over HTTP, repositories, server, client
//   tokenx-android  Android: SQLite database adapter, the Keystore cipher and the TokenX.standard bootstrap
//   tokenx-compose  Compose: TokenXModel plus the settings, usage and status composables a host app embeds
plugins {
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.compose.compiler) apply false
}

allprojects {
    group = "com.bclnet.tokenx"
    version = "1.0.0"
}
