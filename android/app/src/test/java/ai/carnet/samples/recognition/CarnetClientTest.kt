package ai.carnet.samples.recognition

import com.sun.net.httpserver.HttpServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.net.InetSocketAddress

/** The client against a stand-in for the API (a small HTTP server on this computer): no real requests. */
class CarnetClientTest {
    private val car = """
        {"is_success": true, "meta": {"time": 0.07}, "detections": [{"box": {"tl_x": 0.1, "tl_y": 0.2, "br_x": 0.9, "br_y": 0.8},
         "mmg": [{"make_name": "Porsche", "model_name": "Taycan", "generation_name": "I facelift", "years": "2024-", "probability": 0.997},
                 {"make_name": "Porsche", "model_name": "Taycan", "generation_name": "I", "years": "2019-2024", "probability": 0.002}],
         "color": [{"name": "Black", "probability": 0.99}], "angle": [{"name": "front-right", "probability": 1.0}]}]}
    """.trimIndent()

    private lateinit var server: HttpServer
    private val answers = ArrayDeque<Triple<Int, Map<String, String>, String>>()
    private val requests = mutableListOf<Pair<String?, String?>>() // query, api-key

    @Before
    fun start() {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            exchange.requestBody.readBytes()
            requests += exchange.requestURI.rawQuery to exchange.requestHeaders.getFirst("api-key")
            val (status, headers, body) = answers.removeFirstOrNull() ?: Triple(200, emptyMap(), """{"is_success":true,"detections":[]}""")
            headers.forEach { (name, value) -> exchange.responseHeaders.add(name, value) }
            val bytes = body.toByteArray()
            exchange.sendResponseHeaders(status, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
    }

    @After
    fun stop() = server.stop(0)

    private fun client(key: String = "test-key", address: String = "http://127.0.0.1:${server.address.port}/detect") =
        CarnetClient(address, key)

    private fun failure(client: CarnetClient): RecognitionError? =
        try { client.recognize("PHOTO".toByteArray()); null } catch (e: RecognitionError) { e }

    @Test
    fun sendsTheKeyAndParametersAndReadsTheCars() {
        answers += Triple(200, emptyMap(), car)
        val answer = client().recognize("PHOTO".toByteArray())
        assertEquals(1, answer.cars.size)
        assertEquals("Porsche Taycan I facelift", answer.cars[0].guesses[0].name)
        assertEquals("2024-", answer.cars[0].guesses[0].years)
        assertEquals(0.9, answer.cars[0].box!!.right, 0.0)
        assertEquals("Black", answer.cars[0].color)
        assertEquals("front-right", answer.cars[0].angle)
        assertEquals(0.07, answer.time!!, 0.0)
        assertEquals("features=mmg,color,angle&box_select=all" to "test-key", requests.single())
    }

    @Test
    fun noKeyForTheCloudApi() {
        assertTrue(failure(client(key = "", address = CarnetClient.CLOUD_ADDRESS)) is RecognitionError.NoKey)
    }

    @Test
    fun carnetServerNeedsNoKey() {
        answers += Triple(200, emptyMap(), car)
        client(key = "").recognize("PHOTO".toByteArray())
        assertNull(requests.single().second)
    }

    @Test
    fun tooFastWaitsAndTriesOnceMore() {
        answers += Triple(429, mapOf("X-Rate-Limit-Reset" to (System.currentTimeMillis() + 200).toString()),
            """{"message":"Rate limit exceeded ! You reach the limit of 1 requests per 1 seconds"}""")
        answers += Triple(200, emptyMap(), car)
        assertEquals(1, client().recognize("PHOTO".toByteArray()).cars.size)
        assertEquals(2, requests.size)
    }

    @Test
    fun limitUsedUpSaysWhenItRenews() {
        answers += Triple(429, mapOf("X-Quota-Reset" to "1794915965161"),
            """{"message":"Quota exceeded ! You reach the limit of 100 requests per 1 days"}""")
        val error = failure(client()) as RecognitionError.LimitUsedUp
        assertEquals(1794915965161L, error.renews)
        assertTrue(error.message!!.startsWith("The key's limit is used up. It renews at "))
        assertEquals(1, requests.size)
    }

    @Test
    fun plainErrors() {
        answers += Triple(403, emptyMap(), """{"message":"API Key is not valid or is expired / revoked."}""")
        assertTrue(failure(client()) is RecognitionError.KeyRefused)
        answers += Triple(500, emptyMap(), "oops")
        assertEquals(500, (failure(client()) as RecognitionError.ServiceProblem).status)
        answers += Triple(200, emptyMap(), "<html>")
        assertTrue(failure(client()) is RecognitionError.UnreadableAnswer)
        answers += Triple(200, emptyMap(), """{"is_success": false, "error": {"code": 8, "message": "Error decoding image"}, "detections": []}""")
        assertEquals("Error decoding image", failure(client())?.message)
    }

    @Test
    fun yourOwnServersErrorIsShownAsItIs() {
        answers += Triple(503, emptyMap(), """{"error":"This site is busy. Try again in a moment."}""")
        val error = failure(client(key = "", address = "http://127.0.0.1:${server.address.port}/api/recognize"))
        assertTrue(error is RecognitionError.Server)
        assertEquals("This site is busy. Try again in a moment.", error?.message)
    }

    @Test
    fun noAnswer() {
        val port = server.address.port
        server.stop(0)
        assertTrue(failure(client(address = "http://127.0.0.1:$port/detect")) is RecognitionError.NotAnswered)
    }

    @Test
    fun refusesAPhotoOver12MB() {
        try {
            client().recognize(ByteArray(CarnetClient.MAX_BYTES + 1))
            fail("no error")
        } catch (e: RecognitionError.TooLarge) {
            assertTrue(requests.isEmpty())
        }
    }
}
