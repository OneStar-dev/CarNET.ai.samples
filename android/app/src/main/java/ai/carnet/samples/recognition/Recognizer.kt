package ai.carnet.samples.recognition

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What the screen shows: the photo sent, the answer, and a status line. */
class Recognizer(private val app: Application) : AndroidViewModel(app) {
    var photo by mutableStateOf<Bitmap?>(null)
    var answer by mutableStateOf<Answer?>(null)
    var status by mutableStateOf("Take or choose a photo of a car.")
    var isError by mutableStateOf(false)
    var busy by mutableStateOf(false)

    /** A photo from the camera or the photo picker. */
    fun recognize(uri: Uri) = run { app.contentResolver.openInputStream(uri)?.use { it.readBytes() } }

    fun recognizeExample() = run { app.assets.open("example.jpg").use { it.readBytes() } }

    private fun run(read: () -> ByteArray?) {
        if (busy) return
        busy = true
        answer = null
        isError = false
        status = "Recognizing…"
        viewModelScope.launch {
            try {
                // Reading and shrinking a large photo takes a moment: do it off the main thread.
                val (bitmap, jpeg) = withContext(Dispatchers.IO) { read()?.let(PhotoShrinker::jpeg) }
                    ?: throw RecognitionError.PhotoNotOpened()
                photo = bitmap
                val result = withContext(Dispatchers.IO) { Settings(app).client().recognize(jpeg) }
                answer = result
                val time = result.time?.let { String.format(java.util.Locale.ROOT, " The API took %.2f s.", it) } ?: ""
                status = when (result.cars.size) {
                    0 -> "No car recognized in this photo.$time"
                    1 -> "Found 1 car.$time"
                    else -> "Found ${result.cars.size} cars.$time"
                }
            } catch (e: RecognitionError) {
                status = e.message ?: "Something went wrong."
                isError = true
            } catch (e: Exception) {
                status = "Could not open this photo."
                isError = true
            } finally {
                busy = false
            }
        }
    }
}
