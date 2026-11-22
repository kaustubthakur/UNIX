package com.example.btmedia

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.Crossfade
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Forward10
import androidx.compose.material.icons.rounded.Replay10
import androidx.compose.material.icons.rounded.VolumeDown
import androidx.compose.material.icons.rounded.VolumeOff
import androidx.compose.material.icons.rounded.VolumeUp
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { BtMediaTheme { App() } }
    }
}

@Composable
fun BtMediaTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val ctx = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= 31 ->
            if (dark) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}

private fun hasBtPermission(ctx: Context) =
    Build.VERSION.SDK_INT < 31 ||
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

// ---------------------------------------------------------------------------------------
// Root: permission -> device picker -> player
// ---------------------------------------------------------------------------------------

@Composable
fun App(vm: MediaViewModel = viewModel()) {
    val ctx = LocalContext.current
    var granted by remember { mutableStateOf(hasBtPermission(ctx)) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    val conn by vm.conn.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) { if (!granted) ask.launch(Manifest.permission.BLUETOOTH_CONNECT) }
    LaunchedEffect(granted) { if (granted) vm.autoConnect() }

    Surface(Modifier.fillMaxSize()) {
        when {
            !granted -> PermissionScreen { ask.launch(Manifest.permission.BLUETOOTH_CONNECT) }
            conn is Conn.Idle -> DevicePicker(vm)
            else -> PlayerScreen(vm, conn)
        }
    }
}

@Composable
fun PermissionScreen(onAllow: () -> Unit) {
    Column(
        Modifier.fillMaxSize().safeDrawingPadding().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Allow Bluetooth access", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text(
            "The “Nearby devices” permission lets this app talk to your computer.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(24.dp))
        Button(onClick = onAllow) { Text("Allow") }
    }
}

@Composable
fun DevicePicker(vm: MediaViewModel) {
    val devices = remember { vm.pairedDevices() }
    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = 24.dp, vertical = 16.dp)) {
        Text("Pick your computer", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text(
            if (devices.isEmpty()) "No paired devices yet. Pair your computer in Android’s Bluetooth settings, then reopen this app."
            else "Start btmedia.sh on the computer, then tap it here.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(16.dp))
        LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            items(devices, key = { it.address }) { d ->
                ListItem(
                    headlineContent = { Text(d.name) },
                    supportingContent = { Text(d.address) },
                    leadingContent = { Icon(Icons.Rounded.Computer, contentDescription = null) },
                    modifier = Modifier.clip(RoundedCornerShape(16.dp)).clickable { vm.connect(d.address) },
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------------------
// Player
// ---------------------------------------------------------------------------------------

@Composable
fun PlayerScreen(vm: MediaViewModel, conn: Conn) {
    val now by vm.now.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        StatusBar(conn, onChange = vm::switchDevice)

        // Portrait: cover on top, controls below. Landscape: cover left, controls right.
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp)) {
            if (maxWidth > maxHeight) {
                Row(
                    Modifier.fillMaxSize(),
                    horizontalArrangement = Arrangement.spacedBy(32.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Cover(now.cover, Modifier.fillMaxHeight().aspectRatio(1f))
                    PlayerPanel(now, vm, Modifier.weight(1f).verticalScroll(rememberScrollState()))
                }
            } else {
                Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Cover(now.cover, Modifier.weight(1f, fill = false).widthIn(max = 480.dp).aspectRatio(1f))
                    Spacer(Modifier.height(24.dp))
                    PlayerPanel(now, vm, Modifier.fillMaxWidth().widthIn(max = 480.dp))
                    Spacer(Modifier.height(16.dp))
                }
            }
        }
    }
}

@Composable
fun StatusBar(conn: Conn, onChange: () -> Unit) {
    val (text, dot) = when (conn) {
        is Conn.Connected -> conn.device to Color(0xFF2E7D32)
        is Conn.Connecting ->
            (if (conn.attempt > 1) "Reconnecting to ${conn.device}…" else "Connecting to ${conn.device}…") to
                    Color(0xFFF9A825)
        Conn.Idle -> "Not connected" to MaterialTheme.colorScheme.outline
    }
    Column(Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp, top = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).background(dot, CircleShape))
            Spacer(Modifier.width(10.dp))
            Text(
                text,
                Modifier.weight(1f),
                style = MaterialTheme.typography.labelLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            TextButton(onClick = onChange) { Text("Change") }
        }
        if (conn is Conn.Connecting && conn.attempt >= 3) {
            Text(
                "Can’t reach the computer. Check that btmedia.sh is running there.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
fun Cover(bitmap: Bitmap?, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(28.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
        shadowElevation = 8.dp,
    ) {
        Crossfade(targetState = bitmap, label = "cover") { bmp ->
            if (bmp != null) {
                Image(
                    bitmap = remember(bmp) { bmp.asImageBitmap() },
                    contentDescription = "Album art",
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Icon(
                        Icons.Rounded.MusicNote,
                        contentDescription = null,
                        modifier = Modifier.fillMaxSize(0.4f),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
fun PlayerPanel(now: NowPlaying, vm: MediaViewModel, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        TrackInfo(now)
        Progress(now, onSeek = vm::seek)
        Controls(
            playing = now.playing,
            enabled = now.hasPlayer,
            onPrevious = vm::previous,
            onToggle = vm::playPause,
            onNext = vm::next,
        )
        ExtraControls(now, vm)
        VolumeBar(now, onSet = vm::setVolume)
    }
}

@Composable
fun TrackInfo(now: NowPlaying) {
    val title = when {
        !now.hasPlayer -> "Nothing playing"
        now.title.isBlank() -> "Unknown title"
        else -> now.title
    }
    val subtitle = if (now.hasPlayer) {
        listOf(now.artist, now.album).filter { it.isNotBlank() }.joinToString(" • ")
    } else {
        "Start something on your computer"
    }
    Column(Modifier.fillMaxWidth()) {
        Text(
            title,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            subtitle,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (now.hasPlayer && now.player.isNotBlank()) {
            Text(
                "Playing in ${now.player.substringBefore(".instance")}",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary,
            )
        }
    }
}

@Composable
fun Progress(now: NowPlaying, onSeek: (Long) -> Unit) {
    var position by remember { mutableLongStateOf(0L) }
    var dragging by remember { mutableStateOf(false) }
    var dragValue by remember { mutableFloatStateOf(0f) }

    // The phone extrapolates the position locally (4x per second) instead of the
    // computer sending it; a fresh value only arrives on track / play / pause changes.
    LaunchedEffect(now.playing, now.sampledAt, now.lengthMs) {
        position = now.liveMs()
        while (isActive && now.playing) {
            delay(250)
            if (!dragging) position = now.liveMs()
        }
    }

    val max = now.lengthMs.coerceAtLeast(1L).toFloat()
    val shown = if (dragging) dragValue else position.toFloat()

    Column {
        Slider(
            value = shown.coerceIn(0f, max),
            onValueChange = { dragging = true; dragValue = it },
            onValueChangeFinished = {
                position = dragValue.toLong()
                onSeek(position)
                dragging = false
            },
            valueRange = 0f..max,
            enabled = now.hasPlayer && now.lengthMs > 0,
        )
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(formatTime(shown.toLong()), style = MaterialTheme.typography.labelMedium)
            Text(formatTime(now.lengthMs), style = MaterialTheme.typography.labelMedium)
        }
    }
}

@Composable
fun Controls(
    playing: Boolean,
    enabled: Boolean,
    onPrevious: () -> Unit,
    onToggle: () -> Unit,
    onNext: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FilledTonalIconButton(onClick = onPrevious, enabled = enabled, modifier = Modifier.size(64.dp)) {
            Icon(Icons.Rounded.SkipPrevious, contentDescription = "Previous", modifier = Modifier.size(32.dp))
        }
        FilledIconButton(onClick = onToggle, enabled = enabled, modifier = Modifier.size(88.dp)) {
            Icon(
                if (playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                contentDescription = if (playing) "Pause" else "Play",
                modifier = Modifier.size(44.dp),
            )
        }
        FilledTonalIconButton(onClick = onNext, enabled = enabled, modifier = Modifier.size(64.dp)) {
            Icon(Icons.Rounded.SkipNext, contentDescription = "Next", modifier = Modifier.size(32.dp))
        }
    }
}

@Composable
fun ExtraControls(now: NowPlaying, vm: MediaViewModel) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceEvenly,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = vm::seekBack, enabled = now.hasPlayer) {
            Icon(Icons.Rounded.Replay10, contentDescription = "Back 10 seconds")
        }
        //IconButton(onClick = vm::volumeDown) {
          //  Icon(Icons.Rounded.VolumeDown, contentDescription = "Volume down")
        //}
        //IconToggleButton(checked = now.muted, onCheckedChange = { vm.toggleMute() }) {
          //  Icon(Icons.Rounded.VolumeOff, contentDescription = "Mute")
        //}
        //IconButton(onClick = vm::volumeUp) {
          //  Icon(Icons.Rounded.VolumeUp, contentDescription = "Volume up")
        //}
        IconButton(onClick = vm::seekForward, enabled = now.hasPlayer) {
            Icon(Icons.Rounded.Forward10, contentDescription = "Forward 10 seconds")
        }
    }
}

@Composable
fun VolumeBar(now: NowPlaying, onSet: (Int) -> Unit) {
    var dragging by remember { mutableStateOf(false) }
    var dragValue by remember { mutableFloatStateOf(0f) }
    val known = now.volume >= 0
    val shown = if (dragging) dragValue else now.volume.coerceAtLeast(0).toFloat()

    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(
            Icons.Rounded.VolumeUp,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Slider(
            value = shown.coerceIn(0f, 100f),
            onValueChange = { dragging = true; dragValue = it },
            onValueChangeFinished = { onSet(dragValue.toInt()); dragging = false },
            valueRange = 0f..100f,
            enabled = known,
            modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
        )
        Text(
            if (known) "${shown.toInt()}%" else "–",
            modifier = Modifier.width(44.dp),
            textAlign = TextAlign.End,
            style = MaterialTheme.typography.labelMedium,
        )
    }
}

private fun formatTime(ms: Long): String {
    val s = ms / 1000
    return "${s / 60}:${(s % 60).toString().padStart(2, '0')}"
}