package com.example.btmedia

import android.annotation.SuppressLint
import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope

data class Paired(val name: String, val address: String)

@SuppressLint("MissingPermission")   // the UI only calls these after BLUETOOTH_CONNECT is granted
class MediaViewModel(app: Application) : AndroidViewModel(app) {

    private val adapter: BluetoothAdapter? =
        app.getSystemService(BluetoothManager::class.java)?.adapter
    private val prefs = app.getSharedPreferences("btmedia", Context.MODE_PRIVATE)
    private val client = BtMediaClient(viewModelScope, adapter)

    val now = client.now
    val conn = client.conn

    fun pairedDevices(): List<Paired> =
        adapter?.bondedDevices.orEmpty()
            .map { Paired(it.name ?: it.address, it.address) }
            .sortedBy { it.name.lowercase() }

    fun connect(address: String) {
        prefs.edit().putString(KEY_DEVICE, address).apply()
        client.connect(address)
    }

    /** Reconnect to the computer used last time. No-op if already connected or none chosen yet. */
    fun autoConnect() {
        if (conn.value is Conn.Idle) prefs.getString(KEY_DEVICE, null)?.let(client::connect)
    }

    fun switchDevice() {
        client.disconnect()
        prefs.edit().remove(KEY_DEVICE).apply()
    }

    fun playPause() = client.playPause()
    fun next() = client.next()
    fun previous() = client.previous()
    fun seek(ms: Long) = client.seek(ms)
    fun seekBack() = client.seekBack()
    fun seekForward() = client.seekForward()
    fun volumeUp() = client.volumeUp()
    fun volumeDown() = client.volumeDown()
    fun toggleMute() = client.toggleMute()
    fun setVolume(pct: Int) = client.setVolume(pct)

    override fun onCleared() {
        client.disconnect()
    }

    private companion object {
        const val KEY_DEVICE = "last_device"
    }
}