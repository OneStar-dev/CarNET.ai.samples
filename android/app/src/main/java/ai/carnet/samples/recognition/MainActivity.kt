package ai.carnet.samples.recognition

import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import java.io.File

private val Blue = Color(0xFF0A66D8)
private val Muted = Color(0xFF6E6E73)

class MainActivity : ComponentActivity() {
    @OptIn(ExperimentalComposeUiApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(colorScheme = lightColorScheme(primary = Blue)) {
                // testTagsAsResourceId: test tools outside the app (such as UI Automator) can find the tagged parts.
                Surface(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) { App() }
            }
        }
    }
}

@Composable
private fun App(model: Recognizer = viewModel()) {
    var showSettings by rememberSaveable { mutableStateOf(false) }
    if (showSettings) SettingsScreen(onClose = { showSettings = false })
    else MainScreen(model, onSettings = { showSettings = true })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MainScreen(model: Recognizer, onSettings: () -> Unit) {
    val context = LocalContext.current
    val hasCamera = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) }
    // The camera app saves the photo into this app's cache; FileProvider lets it write there.
    val cameraPhoto = remember {
        val file = File(context.cacheDir, "photos").apply { mkdirs() }.resolve("camera.jpg")
        FileProvider.getUriForFile(context, "${context.packageName}.photos", file)
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        if (saved) model.recognize(cameraPhoto)
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        if (uri != null) model.recognize(uri)
    }
    LaunchedEffect(Unit) {
        val settings = Settings(context)
        if (model.answer == null && settings.key.isEmpty() && settings.address == CarnetClient.CLOUD_ADDRESS) {
            model.status = "Add your API key in Settings (top right) first."
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Which car is this?") },
                actions = { TextButton(onClick = onSettings, modifier = Modifier.testTag("settings")) { Text("Settings") } },
            )
        },
        bottomBar = {
            Surface(tonalElevation = 3.dp) {
                Row(
                    Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterHorizontally),
                ) {
                    if (hasCamera) Button(onClick = { camera.launch(cameraPhoto) }, enabled = !model.busy) { Text("Camera") }
                    Button(
                        onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                        enabled = !model.busy,
                        modifier = Modifier.testTag("photos"),
                    ) { Text("Photos") }
                    Button(onClick = model::recognizeExample, enabled = !model.busy, modifier = Modifier.testTag("example")) { Text("Example") }
                }
            }
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            model.photo?.let { PhotoWithBoxes(it, model.answer?.cars.orEmpty()) }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (model.busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Text(
                    model.status,
                    style = MaterialTheme.typography.titleSmall,
                    color = if (model.isError) Color(0xFFC4291C) else Color.Unspecified,
                    modifier = Modifier.testTag("status"),
                )
            }
            model.answer?.cars?.forEachIndexed { index, car -> CarRow(index + 1, car) }
            model.answer?.let { RawAnswer(it.raw) }
        }
    }
}

/** The photo with a numbered box around each car. */
@Composable
private fun PhotoWithBoxes(photo: Bitmap, cars: List<Car>) {
    BoxWithConstraints(
        Modifier.fillMaxWidth().aspectRatio(photo.width.toFloat() / photo.height).clip(RoundedCornerShape(8.dp))
    ) {
        Image(photo.asImageBitmap(), contentDescription = "The photo sent", Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
        cars.forEachIndexed { index, car ->
            val box = car.box ?: return@forEachIndexed
            Box(
                Modifier
                    .offset(x = maxWidth * box.left.toFloat(), y = maxHeight * box.top.toFloat())
                    .size(width = maxWidth * (box.right - box.left).toFloat(), height = maxHeight * (box.bottom - box.top).toFloat())
                    .border(3.dp, Blue)
            ) {
                Text(
                    "${index + 1}",
                    color = Color.White,
                    fontWeight = FontWeight.Bold,
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.background(Blue).padding(horizontal = 6.dp),
                )
            }
        }
    }
}

/** One car: make, model and generation with years, how sure, color, angle, and close alternatives. */
@Composable
private fun CarRow(number: Int, car: Car) {
    val best = car.guesses.first()
    Column(Modifier.testTag("carRow").semantics(mergeDescendants = true) {}) {
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append("$number. ${best.name}") }
                best.years?.let { withStyle(SpanStyle(color = Muted)) { append("  $it") } }
            },
            style = MaterialTheme.typography.titleMedium,
        )
        Text(listOfNotNull("${percent(best.probability)} sure", car.color, car.angle?.let { "$it view" }).joinToString(" · "))
        if (car.guesses.size > 1) {
            Text(
                "Also possible: " + car.guesses.drop(1).joinToString { "${it.name} (${percent(it.probability)})" },
                style = MaterialTheme.typography.bodySmall,
                color = Muted,
            )
        }
    }
}

@Composable
private fun RawAnswer(raw: String) {
    var open by rememberSaveable { mutableStateOf(false) }
    TextButton(onClick = { open = !open }) { Text(if (open) "Hide the API's answer" else "The API's answer", color = Muted) }
    if (open) Text(raw, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
}

private fun percent(p: Double): String {
    val value = Math.round(p * 1000) / 10.0
    return if (value % 1.0 == 0.0) "${value.toInt()}%" else "$value%"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    val settings = remember { Settings(context) }
    var key by rememberSaveable { mutableStateOf(settings.key) }
    var showKey by rememberSaveable { mutableStateOf(false) }
    var address by rememberSaveable { mutableStateOf(settings.address) }
    BackHandler(onBack = onClose)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = { TextButton(onClick = onClose) { Text("Cancel") } },
                actions = {
                    TextButton(onClick = {
                        settings.key = key
                        settings.address = address
                        onClose()
                    }, modifier = Modifier.testTag("done")) { Text("Done") }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                key, { key = it },
                label = { Text("API key") },
                singleLine = true,
                visualTransformation = if (showKey) VisualTransformation.None else PasswordVisualTransformation(),
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Ascii),
                modifier = Modifier.fillMaxWidth().testTag("apiKey"),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(checked = showKey, onCheckedChange = { showKey = it })
                Text("Show the key", Modifier.padding(start = 8.dp))
            }
            Text(
                "Kept in this app's private storage. Get a free trial key at carnet.ai. Leave it empty for CarNET Server or your own server.",
                style = MaterialTheme.typography.bodySmall, color = Muted,
            )
            OutlinedTextField(
                address, { address = it },
                label = { Text("API address") },
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth().testTag("apiAddress"),
            )
            TextButton(onClick = { address = CarnetClient.CLOUD_ADDRESS }) { Text("Use the Cloud API") }
            Text(
                "CarNET Server: http://YOUR-SERVER:50052/detect. An app you publish should send photos to your own server, " +
                    "which adds the key, such as the micro website's https://YOUR-SITE/api/recognize.",
                style = MaterialTheme.typography.bodySmall, color = Muted,
            )
        }
    }
}
