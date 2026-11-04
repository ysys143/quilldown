package com.quilldown.viewer

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject

/**
 * Persists metadata for the last N markdown files the user opened so we can
 * render a Samsung-My-Files-style list on the empty screen (filename, size,
 * timestamp, and a short content preview).
 *
 * URIs are stored as strings and must be re-granted via
 * `takePersistableUriPermission` when the user picks them. If that grant
 * has since been revoked (device reboot, OS policy, file moved), we drop
 * the entry silently on read.
 */
class RecentFilesStore(context: Context) {

    data class Entry(
        val uri: Uri,
        val name: String,
        val openedAt: Long,
        val size: Long,
        val preview: String,
    )

    private val prefs: SharedPreferences =
        context.getSharedPreferences("recent_files", Context.MODE_PRIVATE)

    fun add(uri: Uri, name: String, size: Long, preview: String) {
        val current = load().filter { it.uri != uri }
        val updated = (listOf(
            Entry(uri, name, System.currentTimeMillis(), size, preview)
        ) + current).take(MAX)
        save(updated)
    }

    fun remove(uri: Uri) {
        save(load().filter { it.uri != uri })
    }

    fun load(): List<Entry> {
        val raw = prefs.getString(KEY, null) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val obj = arr.optJSONObject(i) ?: return@mapNotNull null
                val uriStr = obj.optString("uri").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                Entry(
                    uri = Uri.parse(uriStr),
                    name = obj.optString("name", uriStr),
                    openedAt = obj.optLong("at", 0L),
                    size = obj.optLong("size", -1L),
                    preview = obj.optString("preview", ""),
                )
            }
        }.getOrDefault(emptyList())
    }

    private fun save(entries: List<Entry>) {
        val arr = JSONArray()
        entries.forEach {
            arr.put(JSONObject().apply {
                put("uri", it.uri.toString())
                put("name", it.name)
                put("at", it.openedAt)
                put("size", it.size)
                put("preview", it.preview)
            })
        }
        prefs.edit().putString(KEY, arr.toString()).apply()
    }

    companion object {
        private const val KEY = "entries"
        private const val MAX = 20
    }
}
