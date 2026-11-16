package ai.carnet.samples.recognition

import android.content.Context

/** The app's two settings, in its private storage: the API address and the API key. */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    var address: String
        get() = prefs.getString("address", null) ?: CarnetClient.CLOUD_ADDRESS
        set(value) = prefs.edit().putString("address", value.trim()).apply()

    var key: String
        get() = prefs.getString("key", null) ?: ""
        set(value) = prefs.edit().putString("key", value.trim()).apply()

    fun client() = CarnetClient(address, key)
}
