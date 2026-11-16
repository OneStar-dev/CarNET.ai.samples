package ai.carnet.samples.recognition

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.text.DateFormat
import java.util.Date

/**
 * Sends one photo to the CarNET API and reads the answer.
 *
 * The address can be the Cloud API (needs your key), CarNET Server (no key), or your own server that adds the key,
 * such as the micro website's `/api/recognize` in this repo. An app you publish should use your own server: a key
 * inside an app can be taken out of it.
 */
class CarnetClient(private val address: String, private val key: String) {

    companion object {
        const val CLOUD_ADDRESS = "https://api.carnet.ai/v2/mmg/detect"

        /** What we ask for: make, model and generation, body color and angle, for every car in the photo. */
        const val QUERY = "features=mmg,color,angle&box_select=all"
        const val MAX_BYTES = 12 * 1024 * 1024 // the Cloud API takes photos up to 12 MB
    }

    /** Blocking: call it off the main thread. Throws [RecognitionError] with a message to show. */
    fun recognize(photo: ByteArray): Answer {
        if (photo.size > MAX_BYTES) throw RecognitionError.TooLarge()
        if (key.isEmpty() && address.startsWith("https://api.carnet.ai/")) throw RecognitionError.NoKey()
        val url = try {
            URL(address + (if ("?" in address) "&" else "?") + QUERY)
        } catch (e: Exception) {
            throw RecognitionError.BadAddress()
        }
        if (url.protocol != "http" && url.protocol != "https") throw RecognitionError.BadAddress()

        var reply = send(url, photo)
        // Too fast for the key's per-second limit: wait for the next second and try once more. (Your own server's
        // refusals come as {"error": …}: it has already tried again itself.)
        if (reply.status == 429 && !reply.limitUsedUp && ownServerError(reply.body) == null) {
            Thread.sleep(reply.waitForRate())
            reply = send(url, photo)
        }
        return read(reply)
    }

    private fun send(url: URL, photo: ByteArray): Reply {
        val connection = url.openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false // the key (and the photo) never go on to an address you didn't set
            connection.doOutput = true
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("Content-Type", "application/octet-stream")
            if (key.isNotEmpty()) connection.setRequestProperty("api-key", key)
            connection.setFixedLengthStreamingMode(photo.size)
            connection.outputStream.use { it.write(photo) }
            val status = connection.responseCode
            val body = (if (status >= 400) connection.errorStream else connection.inputStream)
                ?.bufferedReader()?.use { it.readText() } ?: ""
            val headers = connection.headerFields.filterKeys { it != null }
                .mapKeys { it.key.lowercase() }.mapValues { it.value.lastOrNull() ?: "" }
            return Reply(status, body, headers)
        } catch (e: IOException) {
            throw RecognitionError.NotAnswered()
        } finally {
            connection.disconnect()
        }
    }

    /** One HTTP answer. Header names are lower case. */
    class Reply(val status: Int, val body: String, val headers: Map<String, String>) {
        val limitUsedUp get() = "Quota exceeded" in body

        /** X-Rate-Limit-Reset (Unix time in milliseconds), kept between 0.1 and 1.1 s so a clock that is off
         * can't make the app wait long. */
        fun waitForRate(): Long {
            val reset = headers["x-rate-limit-reset"]?.toLongOrNull() ?: return 1000
            return (reset - System.currentTimeMillis()).coerceIn(100, 1100)
        }
    }

    /** Turns an HTTP answer into the API's answer or a plain error. */
    internal fun read(reply: Reply): Answer {
        val json = try { JSONObject(reply.body) } catch (e: Exception) { null }
        val ownError = ownServerError(reply.body)
        if (reply.status != 200 && ownError != null) throw RecognitionError.Server(ownError)
        when (reply.status) {
            200 -> {}
            401, 403 -> throw RecognitionError.KeyRefused()
            413 -> throw RecognitionError.TooLarge()
            429 -> {
                if (reply.limitUsedUp) throw RecognitionError.LimitUsedUp(reply.headers["x-quota-reset"]?.toLongOrNull())
                throw RecognitionError.TooFast()
            }
            else -> throw RecognitionError.ServiceProblem(reply.status)
        }
        if (json == null) throw RecognitionError.UnreadableAnswer()
        if (!json.optBoolean("is_success")) {
            throw RecognitionError.PhotoNotRead(json.optJSONObject("error")?.text("message") ?: "The API could not read the photo.")
        }
        val detections = json.optJSONArray("detections") ?: JSONArray()
        val cars = (0 until detections.length()).map { detections.getJSONObject(it) }.mapNotNull(::car)
        return Answer(cars, json.optJSONObject("meta")?.optDouble("time")?.takeIf { !it.isNaN() }, json.toString(2))
    }

    /** Your own server (like the micro website) answers its errors as {"error": "…"}. */
    private fun ownServerError(body: String): String? =
        try { JSONObject(body).opt("error") as? String } catch (e: Exception) { null }

    /** A detection that comes with a make and model is a car (mmg, or mm when only those were asked for). */
    private fun car(detection: JSONObject): Car? {
        val list = detection.optJSONArray("mmg") ?: detection.optJSONArray("mm") ?: return null
        val guesses = (0 until list.length()).map { list.getJSONObject(it) }.map {
            Guess(it.text("make_name") ?: "", it.text("model_name") ?: "", it.text("generation_name"), it.text("years"), it.optDouble("probability"))
        }
        if (guesses.isEmpty()) return null
        val box = detection.optJSONObject("box")?.let {
            Box(it.optDouble("tl_x"), it.optDouble("tl_y"), it.optDouble("br_x"), it.optDouble("br_y"))
        }
        val top = { name: String -> detection.optJSONArray(name)?.optJSONObject(0)?.text("name") }
        return Car(box, guesses, top("color"), top("angle"))
    }

    private fun JSONObject.text(name: String): String? = if (isNull(name)) null else optString(name).ifEmpty { null }
}

/** The API's answer to one photo: the cars, the API's time in seconds, and its JSON for showing. */
data class Answer(val cars: List<Car>, val time: Double?, val raw: String)

/** One car: where it is (fractions of the photo's width and height), the top guesses, color and angle. */
data class Car(val box: Box?, val guesses: List<Guess>, val color: String?, val angle: String?)

data class Box(val left: Double, val top: Double, val right: Double, val bottom: Double)

data class Guess(val make: String, val model: String, val generation: String?, val years: String?, val probability: Double) {
    val name get() = listOfNotNull(make, model, generation).filter { it.isNotEmpty() }.joinToString(" ")
}

sealed class RecognitionError(message: String) : Exception(message) {
    class NoKey : RecognitionError("Add your API key in Settings.")
    class BadAddress : RecognitionError("The API address in Settings isn't a web address.")
    class NotAnswered : RecognitionError("Could not reach the recognition service. Check your connection and try again.")
    class KeyRefused : RecognitionError("The API key was refused. Check it in Settings.")
    class TooFast : RecognitionError("Too many photos at once. Try again in a second.")
    class TooLarge : RecognitionError("The photo is larger than 12 MB.")
    class UnreadableAnswer : RecognitionError("The recognition service gave an answer this app could not read.")
    class LimitUsedUp(val renews: Long?) : RecognitionError(
        if (renews != null) "The key's limit is used up. It renews at ${DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(renews))}."
        else "The key's limit is used up for now."
    )
    class ServiceProblem(val status: Int) : RecognitionError("The recognition service had a problem (HTTP $status). Try again in a moment.")
    class PhotoNotRead(message: String) : RecognitionError(message)
    class Server(message: String) : RecognitionError(message)
    class PhotoNotOpened : RecognitionError("Could not open this photo.")
}
