package xyz.block.buzz.androidpush

import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry

/**
 * Flutter plugin entry point for Buzz Android notifications.
 *
 * The engine side remains usable without an Activity so a headless Flutter
 * isolate can render a notification after its authenticated fetch. Permission
 * and settings operations fail explicitly until an Activity is attached.
 */
class BuzzAndroidPushPlugin : FlutterPlugin, ActivityAware, PluginRegistry.NewIntentListener {
    private var bridge: BuzzAndroidPushBridge? = null
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        bridge = BuzzAndroidPushBridge(binding.applicationContext).also {
            it.attachMessenger(binding.binaryMessenger)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        bridge?.dispose()
        bridge = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        bridge?.attachActivity(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
        bridge?.detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
        bridge?.detachActivity()
    }

    override fun onNewIntent(intent: Intent): Boolean {
        return bridge?.handleNotificationIntent(intent) == true
    }
}
