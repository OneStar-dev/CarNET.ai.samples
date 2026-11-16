package ai.carnet.samples.recognition

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min

/**
 * Makes the JPEG that is sent: at most 2,048 pixels on the long side, upright, without the photo's metadata
 * (no location or camera details).
 *
 * That's about a quarter of a phone photo's upload. In our check with 15 phone photos, the answers the API was sure
 * about stayed the same as for the full photo; cars far away may be skipped, because the API leaves out cars less
 * than 180 pixels wide in the photo it receives. Raise [LONG_SIDE] to send larger photos (the API takes up to 12 MB).
 */
object PhotoShrinker {
    const val LONG_SIDE = 2048
    const val QUALITY = 85

    /** The bitmap to show and the JPEG to send, or null when the photo can't be read. */
    fun jpeg(photo: ByteArray): Pair<Bitmap, ByteArray>? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(photo, 0, photo.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        // Decode at a power-of-two fraction that still has at least LONG_SIDE pixels, so a 48-megapixel photo
        // never sits in memory at full size, then scale to exactly LONG_SIDE.
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= LONG_SIDE) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(photo, 0, photo.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return null

        val scale = min(1f, LONG_SIDE.toFloat() / max(decoded.width, decoded.height))
        val matrix = Matrix().apply {
            postScale(scale, scale)
            postConcat(upright(photo))
        }
        val upright = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        val jpeg = ByteArrayOutputStream().also { upright.compress(Bitmap.CompressFormat.JPEG, QUALITY, it) }.toByteArray()
        return upright to jpeg
    }

    /** The turn (and mirror) that the camera's rotation flag asks for. */
    private fun upright(photo: ByteArray): Matrix {
        val orientation = try {
            ExifInterface(ByteArrayInputStream(photo)).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } catch (e: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        return Matrix().apply {
            when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> postRotate(90f)
                ExifInterface.ORIENTATION_ROTATE_180 -> postRotate(180f)
                ExifInterface.ORIENTATION_ROTATE_270 -> postRotate(270f)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> postScale(-1f, 1f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> postScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> { postRotate(90f); postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_TRANSVERSE -> { postRotate(270f); postScale(-1f, 1f) }
            }
        }
    }
}
