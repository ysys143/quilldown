package com.quilldown.viewer

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.TextView
import org.json.JSONObject

/**
 * Single-screen markdown viewer. Loads the same `render.html` + bundled
 * markdown-it / KaTeX / Prism assets used by the macOS build, so rendering
 * fidelity is identical. No editor, no ads, no network.
 */
class MainActivity : Activity() {
    private lateinit var webView: WebView
    private lateinit var emptyState: TextView
    private var pendingMarkdown: String? = null
    private var pageLoaded = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        webView = findViewById(R.id.web_view)
        emptyState = findViewById(R.id.empty_state)

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

        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val uri: Uri = intent?.data ?: return
        val text = runCatching {
            contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
        }.getOrNull() ?: return
        emptyState.visibility = View.GONE
        webView.visibility = View.VISIBLE
        if (pageLoaded) inject(text) else pendingMarkdown = text
        title = uri.lastPathSegment?.substringAfterLast('/') ?: getString(R.string.app_name)
    }

    private fun inject(markdown: String) {
        // Use JSONObject.quote for bullet-proof JS string escaping, matching
        // the JSONEncoder approach on the macOS side.
        val md = JSONObject.quote(markdown)
        val base = JSONObject.quote("")
        webView.evaluateJavascript("render($md, $base);", null)
    }
}
