plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false // sets the Kotlin version the Android plugin uses
    alias(libs.plugins.kotlin.compose) apply false
}
