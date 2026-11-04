package com.quilldown.viewer

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toolbar
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/**
 * Single-screen markdown viewer. Loads the same `render.html` + bundled
 * markdown-it / KaTeX / Prism assets used by the macOS build, so rendering
 * fidelity is identical. No editor, no ads, no network.
 *
 * Three entry points to open a file:
 *  1. External `ACTION_VIEW` intent (file manager, Drive, share sheet)
 *  2. "Open File" button → `ACTION_OPEN_DOCUMENT` (system file picker)
 *  3. Tapping an item in the recent-files list on the empty screen
 */
class MainActivity : androidx.activity.ComponentActivity() {

    private lateinit var webView: WebView
    private lateinit var emptyState: View
    private lateinit var recentList: LinearLayout
    private lateinit var recentHeader: TextView
    private lateinit var toolbar: Toolbar

    private lateinit var recent: RecentFilesStore
    private var pendingMarkdown: String? = null
    private var pageLoaded = false

    private val pickFile = registerForActivityResult(
        object : androidx.activity.result.contract.ActivityResultContract<Unit, Uri?>() {
            override fun createIntent(context: android.content.Context, input: Unit): Intent {
                return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(
                        Intent.EXTRA_MIME_TYPES,
                        arrayOf("text/markdown", "text/x-markdown", "text/plain", "*/*"),
                    )
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }
            }

            override fun parseResult(resultCode: Int, intent: Intent?): Uri? {
                if (resultCode != Activity.RESULT_OK) return null
                return intent?.data
            }
        },
    ) { uri: Uri? ->
        if (uri != null) openUri(uri, persistGrant = true)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        recent = RecentFilesStore(this)
        setContentView(R.layout.activity_main)

        toolbar = findViewById(R.id.toolbar)
        webView = findViewById(R.id.web_view)
        emptyState = findViewById(R.id.empty_state)
        recentList = findViewById(R.id.recent_list)
        recentHeader = findViewById(R.id.recent_header)

        toolbar.title = getString(R.string.app_name)
        toolbar.inflateMenu(R.menu.main_menu)
        toolbar.setOnMenuItemClickListener { item ->
            if (item.itemId == R.id.action_open) {
                pickFile.launch(Unit)
                true
            } else false
        }
        findViewById<Button>(R.id.open_button).setOnClickListener { pickFile.launch(Unit) }

        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)
        with(webView.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = true
            allowContentAccess = true
            builtInZoomControls = true
            displayZoomControls = false
            useWideViewPort = false
            loadWithOverviewMode = false
        }
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                pageLoaded = true
                pendingMarkdown?.let {
                    inject(it)
                    pendingMarkdown = null
                }
            }
        }
        webView.loadUrl("file:///android_asset/render.html")

        renderEmptyState()
        intent?.data?.let { openUri(it, persistGrant = false) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.let { openUri(it, persistGrant = false) }
    }

    // -----------------------------------------------------------------
    // File handling
    // -----------------------------------------------------------------

    private fun openUri(uri: Uri, persistGrant: Boolean) {
        if (persistGrant) {
            val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
            runCatching { contentResolver.takePersistableUriPermission(uri, flags) }
        }
        val text = runCatching {
            contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
        }.getOrNull()
        if (text == null) {
            // Lost permission (e.g. persisted URI no longer valid). Drop from
            // recents so the user isn't offered a broken entry again.
            recent.remove(uri)
            renderEmptyState()
            return
        }

        val (name, size) = queryNameAndSize(uri)
        recent.add(uri, name, size, makePreview(text))
        toolbar.title = name

        emptyState.visibility = View.GONE
        webView.visibility = View.VISIBLE
        if (pageLoaded) inject(text) else pendingMarkdown = text
    }

    private fun queryNameAndSize(uri: Uri): Pair<String, Long> {
        val cols = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        contentResolver.query(uri, cols, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val nameIdx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIdx = c.getColumnIndex(OpenableColumns.SIZE)
                val n = if (nameIdx >= 0) c.getString(nameIdx) else null
                val s = if (sizeIdx >= 0) c.getLong(sizeIdx) else -1L
                if (!n.isNullOrEmpty()) return n to s
            }
        }
        val fallback = uri.lastPathSegment?.substringAfterLast('/')?.ifEmpty { null }
            ?: uri.toString()
        return fallback to -1L
    }

    private fun makePreview(markdown: String): String {
        // Strip common markdown punctuation so the snippet reads like a
        // summary rather than raw source — similar to Samsung's auto-summary.
        val cleaned = markdown
            .replace(Regex("^#{1,6}\\s+", RegexOption.MULTILINE), "")
            .replace(Regex("\\*\\*|\\*|~~|`"), "")
            .replace(Regex("\\[([^\\]]+)\\]\\([^)]+\\)"), "$1")
            .replace(Regex("^[-*+]\\s+", RegexOption.MULTILINE), "")
            .replace(Regex("^>\\s*", RegexOption.MULTILINE), "")
            .replace(Regex("\\s+"), " ")
            .trim()
        return cleaned.take(200)
    }

    private fun inject(markdown: String) {
        // JSONObject.quote gives us bullet-proof JS string escaping — mirrors
        // the JSONEncoder approach used on the macOS side.
        val md = JSONObject.quote(markdown)
        val base = JSONObject.quote("")
        webView.evaluateJavascript("render($md, $base);", null)
    }

    // -----------------------------------------------------------------
    // Empty state UI (welcome + recent files list)
    // -----------------------------------------------------------------

    private fun renderEmptyState() {
        val entries = recent.load()
        recentList.removeAllViews()
        if (entries.isEmpty()) {
            recentHeader.visibility = View.GONE
            return
        }
        recentHeader.visibility = View.VISIBLE
        val inflater = LayoutInflater.from(this)
        val df = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
        entries.forEach { entry ->
            val row = inflater.inflate(R.layout.item_recent, recentList, false)
            row.findViewById<TextView>(R.id.item_name).text = entry.name
            row.findViewById<TextView>(R.id.item_meta).text = df.format(Date(entry.openedAt))
            row.findViewById<TextView>(R.id.item_size).text =
                if (entry.size > 0) humanSize(entry.size) else ""
            val previewView = row.findViewById<TextView>(R.id.item_preview)
            if (entry.preview.isNotBlank()) {
                previewView.visibility = View.VISIBLE
                previewView.text = entry.preview
            } else {
                previewView.visibility = View.GONE
            }
            row.setOnClickListener { openUri(entry.uri, persistGrant = false) }
            recentList.addView(row)
        }
    }

    private fun humanSize(bytes: Long): String {
        val kb = bytes / 1024.0
        return when {
            bytes < 1024 -> "$bytes B"
            kb < 1024.0 -> String.format(Locale.US, "%.1f KB", kb)
            else -> String.format(Locale.US, "%.2f MB", kb / 1024.0)
        }
    }
}
