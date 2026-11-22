package com.example.btmedia

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothSocket
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.SystemClock
import android.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.util.UUID

private val SPP: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
private const val US = '\u001f'   // field separator used by btmedia.sh

data class NowPlaying(
    val hasPlayer: Boolean = false,
    val playing: Boolean = false,
    val title: String = "",
    val artist: String = "",
    val album: String = "",
    val positionMs: Long = 0,
    val lengthMs: Long = 0,
    val sampledAt: Long = 0,          // SystemClock.elapsedRealtime() when positionMs was measured
    val cover: Bitmap? = null,
    val volume: Int = -1,             // percent, -1 = not known yet
    val muted: Boolean = false,
    val player: String = "",          // name of the active player on the computer
) {
    /** Position extrapolated from the last update, so the progress bar needs no extra traffic. */
    fun liveMs(): Long {
        val p = if (playing) positionMs + (SystemClock.elapsedRealtime() - sampledAt) else positionMs
        return if (lengthMs > 0) p.coerceIn(0, lengthMs) else p.coerceAtLeast(0)
    }
}

sealed interface Conn {
    data object Idle : Conn
    data class Connecting(val device: String, val attempt: Int) : Conn
    data class Connected(val device: String) : Conn
}

@SuppressLint("MissingPermission")   // the UI only calls this after BLUETOOTH_CONNECT is granted
class BtMediaClient(
    private val scope: CoroutineScope,
    private val adapter: BluetoothAdapter?,
) {
    private val _now = MutableStateFlow(NowPlaying())
    val now: StateFlow<NowPlaying> = _now

    private val _conn = MutableStateFlow<Conn>(Conn.Idle)
    val conn: StateFlow<Conn> = _conn

    private val commands = Channel<String>(Channel.UNLIMITED)
    @Volatile private var socket: BluetoothSocket? = null
    private var job: Job? = null

    fun connect(address: String) {
        val ad = adapter ?: return
        val device = ad.getRemoteDevice(address)
        val label = device.name ?: address

        job?.cancel()
        socket?.closeQuietly()

        job = scope.launch(Dispatchers.IO) {
            var attempt = 0
            while (isActive) {
                attempt++
                _conn.value = Conn.Connecting(label, attempt)
                try {
                    val s = device.createRfcommSocketToServiceRecord(SPP)
                    socket = s
                    ad.cancelDiscovery()              // discovery slows a connect down a lot
                    s.connect()
                    attempt = 0
                    _conn.value = Conn.Connected(label)
                    session(s)
                } catch (e: IOException) {
                    // connect failed or the link dropped: retry below
                } catch (e: SecurityException) {
                    _conn.value = Conn.Idle           // permission was revoked
                    break
                } finally {
                    socket?.closeQuietly()
                    socket = null
                    _now.value = NowPlaying()
                }
                delay(minOf(1_000L * (attempt + 1), 5_000L))
            }
        }
    }

    fun disconnect() {
        job?.cancel()
        job = null
        socket?.closeQuietly()      // also unblocks a pending connect()/read
        _conn.value = Conn.Idle
        _now.value = NowPlaying()
    }

    // ---- commands (queued, written off the main thread) ----------------------------

    fun playPause() {
        // flip the button immediately; the real state arrives a moment later and wins
        _now.update {
            if (!it.hasPlayer) it
            else it.copy(positionMs = it.liveMs(), sampledAt = SystemClock.elapsedRealtime(), playing = !it.playing)
        }
        send("PLAY_PAUSE")
    }

    fun next() = send("NEXT")
    fun previous() = send("PREV")

    // The commands below only send a name. What they actually do (seek step, volume
    // step, which audio system to use) is decided by mediactl.sh on the computer.
    fun seekBack() = send("SEEK_BACK")
    fun seekForward() = send("SEEK_FWD")
    fun volumeUp() = send("VOL_UP")
    fun volumeDown() = send("VOL_DOWN")

    fun toggleMute() {
        _now.update { it.copy(muted = !it.muted) }      // instant feedback, real state follows
        send("MUTE")
    }

    fun setVolume(pct: Int) {
        _now.update { it.copy(volume = pct) }
        send("VOL $pct")
    }

    fun seek(ms: Long) {
        _now.update { it.copy(positionMs = ms, sampledAt = SystemClock.elapsedRealtime()) }
        send("SEEK ${ms / 1000.0}")
    }

    private fun send(cmd: String) {
        commands.trySend(cmd)
    }

    // ---- one live connection ---------------------------------------------------------

    private suspend fun session(s: BluetoothSocket) = coroutineScope {
        while (commands.tryReceive().isSuccess) { /* drop commands queued while offline */ }

        val writer = launch {
            try {
                val os = s.outputStream
                for (cmd in commands) {
                    os.write("$cmd\n".toByteArray())
                    os.flush()
                }
            } catch (e: IOException) {
                s.closeQuietly()    // makes the blocking read below fail, ending the session
            }
        }
        try {
            val reader = BufferedReader(InputStreamReader(s.inputStream, Charsets.UTF_8), 1 shl 16)
            while (true) {
                val line = reader.readLine() ?: break
                handle(line)
            }
        } finally {
            writer.cancel()
        }
    }

    private fun handle(line: String) {
        val f = line.split(US, limit = 7)
        when (f[0]) {
            "NOW" -> if (f.size == 7) {
                val status = f[1]
                _now.update {
                    it.copy(
                        hasPlayer = status.isNotEmpty(),
                        playing = status == "Playing",
                        positionMs = (f[2].toLongOrNull() ?: 0L) / 1000,    // microseconds -> ms
                        lengthMs = (f[3].toLongOrNull() ?: 0L) / 1000,
                        sampledAt = SystemClock.elapsedRealtime(),
                        title = f[4],
                        artist = f[5],
                        album = f[6],
                    )
                }
            }
            "ART" -> {
                val cover: Bitmap? = f.getOrNull(1)?.takeIf { it.isNotEmpty() }?.let { b64 ->
                    val bytes = Base64.decode(b64, Base64.DEFAULT)
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                }
                _now.update { it.copy(cover = cover) }
            }
            "VOL" -> f.getOrNull(1)?.toIntOrNull()?.let { pct ->
                _now.update { it.copy(volume = pct, muted = f.getOrNull(2) == "1") }
            }
            "PLAYER" -> _now.update { it.copy(player = f.getOrElse(1) { "" }) }
        }
    }
}

private fun BluetoothSocket.closeQuietly() {
    runCatching { close() }
}