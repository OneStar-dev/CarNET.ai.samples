package ai.carnet.samples.recognition

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.File

/** Runs on a phone or emulator: `./gradlew connectedDebugAndroidTest`. */
@RunWith(AndroidJUnit4::class)
class PhotoShrinkerTest {
    private val dir = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir

    /** A 40 x 20 JPEG with its top-left corner red, carrying the given rotation flag (and a location and camera). */
    private fun photo(orientation: Int): File {
        val bitmap = Bitmap.createBitmap(40, 20, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).apply {
            drawColor(Color.WHITE)
            drawRect(0f, 0f, 8f, 8f, Paint().apply { color = Color.RED })
        }
        val file = File(dir, "orientation-$orientation.jpg")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it) }
        ExifInterface(file.path).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString())
            setAttribute(ExifInterface.TAG_GPS_LATITUDE, "59/1,26/1,13/1")
            setAttribute(ExifInterface.TAG_GPS_LATITUDE_REF, "N")
            setAttribute(ExifInterface.TAG_MODEL, "Galaxy S9")
            saveAttributes()
        }
        return file
    }

    private fun isRed(bitmap: Bitmap, x: Int, y: Int): Boolean {
        val pixel = bitmap.getPixel(x, y)
        return Color.red(pixel) > 200 && Color.green(pixel) < 80 && Color.blue(pixel) < 80
    }

    @Test
    fun everyRotationFlagComesOutUpright() {
        // flag -> width, height, and where the red corner must be once upright
        val expected = mapOf(
            1 to Triple(40, 20, 2 to 2), 2 to Triple(40, 20, 37 to 2), 3 to Triple(40, 20, 37 to 17), 4 to Triple(40, 20, 2 to 17),
            5 to Triple(20, 40, 2 to 2), 6 to Triple(20, 40, 17 to 2), 7 to Triple(20, 40, 17 to 37), 8 to Triple(20, 40, 2 to 37),
        )
        for ((flag, want) in expected) {
            val file = photo(flag)
            val (_, jpeg) = PhotoShrinker.jpeg { file.inputStream() }!!
            val sent = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
            assertEquals("flag $flag width", want.first, sent.width)
            assertEquals("flag $flag height", want.second, sent.height)
            assertTrue("flag $flag: the red corner isn't at ${want.third}", isRed(sent, want.third.first, want.third.second))
        }
    }

    @Test
    fun thePhotoSentCarriesNoLocationOrCamera() {
        val file = photo(ExifInterface.ORIENTATION_NORMAL)
        val (_, jpeg) = PhotoShrinker.jpeg { file.inputStream() }!!
        val sent = ExifInterface(ByteArrayInputStream(jpeg))
        assertNull(sent.getAttribute(ExifInterface.TAG_GPS_LATITUDE))
        assertNull(sent.getAttribute(ExifInterface.TAG_MODEL))
    }

    @Test
    fun aLargePhotoIsShrunkTo2048() {
        val big = Bitmap.createBitmap(6000, 4000, Bitmap.Config.RGB_565)
        val file = File(dir, "big.jpg")
        file.outputStream().use { big.compress(Bitmap.CompressFormat.JPEG, 80, it) }
        val (shown, _) = PhotoShrinker.jpeg { file.inputStream() }!!
        assertEquals(2048, shown.width)
        assertEquals(1365, shown.height)
    }
}
