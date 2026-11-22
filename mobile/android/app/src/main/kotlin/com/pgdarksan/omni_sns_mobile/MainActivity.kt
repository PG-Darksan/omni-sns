package com.pgdarksan.omni_sns_mobile

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var webViewManager: OmniWebViewManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val manager = OmniWebViewManager(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        webViewManager = manager
        flutterEngine.platformViewsController.registry.registerViewFactory(
            OmniWebViewManager.VIEW_TYPE,
            manager.createViewFactory(),
        )
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (webViewManager?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        webViewManager?.destroy()
        webViewManager = null
        super.onDestroy()
    }
}
