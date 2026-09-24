package xyz.block.buzz.androidpush

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Android side of the Flutter `buzz/push` channel. */
internal class BuzzAndroidPushBridge(
    private val context: Context,
) {
    private val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val pendingStore = BuzzNotificationPendingStore(
        context.getSharedPreferences(PENDING_STORE_NAME, Context.MODE_PRIVATE),
    )
    private val responseBuffer = BuzzPendingNotificationResponseBuffer()
    private val restrictionFence = BuzzNotificationRestrictionFence(preferences)
    private val snapshotStore = BuzzPushSnapshotStore(preferences)
    private val dedupStore = BuzzNotificationDedupStore(
        context.getSharedPreferences(DEDUP_PREFERENCES_NAME, Context.MODE_PRIVATE),
    )
    private val renderer = BuzzNotificationRenderer(
        context = context,
        pendingStore = pendingStore,
        restrictionFence = restrictionFence,
        snapshotStore = snapshotStore,
        dedupStore = dedupStore,
    )
    private var activity: Activity? = null
    private var channel: MethodChannel? = null

    init {
        BuzzNotificationChannels.ensure(context)
    }

    fun attachMessenger(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL_NAME).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                handleMethodCall(call, result)
            }
        }
    }

    fun dispose() {
        channel?.setMethodCallHandler(null)
        channel = null
        activity = null
    }

    fun attachActivity(attachedActivity: Activity) {
        activity = attachedActivity
        handleNotificationIntent(attachedActivity.intent)
    }

    fun detachActivity() {
        activity = null
    }

    fun handleNotificationIntent(intent: Intent?): Boolean {
        if (intent?.action != OPEN_NOTIFICATION_ACTION) return false
        val envelope = synchronized(BuzzNotificationProcessLock.value) {
            val token = intent.getStringExtra(NOTIFICATION_TOKEN_EXTRA) ?: return false
            val consumed = pendingStore.consume(token) ?: return false
            responseBuffer.record(consumed)
            consumed
        }
        deliverWarmResponse(envelope)
        return true
    }

    /** Called by a future verified transport adapter or by the Flutter isolate. */
    fun renderNotification(envelope: BuzzNotificationEnvelope): Boolean =
        renderer.render(envelope)

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "notificationAuthorizationStatus" -> result.success(readAuthorizationStatus())
            "startRegistration" -> startRegistration(result)
            "openNotificationSettings" -> openNotificationSettings(result)
            "takePendingNotificationResponse" -> takePendingNotificationResponse(result)
            "showNotification" -> showNotification(call.arguments, result)
            "syncPushSnapshot" -> syncPushSnapshot(call.arguments, strict = false, result = result)
            "syncAgeGatePushSnapshot" -> syncPushSnapshot(call.arguments, strict = true, result = result)
            "purgeAgeRestrictedNotifications" -> purgeAgeRestrictedNotifications(result)
            "restoreAgeRestrictedNotifications" -> restoreAgeRestrictedNotifications(result)
            else -> result.notImplemented()
        }
    }

    private fun readAuthorizationStatus(): String {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return if (preferences.getBoolean(PERMISSION_REQUESTED_KEY, false)) {
                "denied"
            } else {
                "notDetermined"
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            !manager.areNotificationsEnabled()
        ) return "denied"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(BuzzNotificationChannels.MESSAGE_CHANNEL_ID)
                ?.importance == NotificationManager.IMPORTANCE_NONE
        ) return "denied"
        return "authorized"
    }

    private fun startRegistration(result: MethodChannel.Result) {
        val currentActivity = activity ?: run {
            result.error(
                "activity_unavailable",
                "Notification permission requires a foreground activity.",
                null,
            )
            return
        }
        BuzzNotificationChannels.ensure(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            preferences.edit().putBoolean(PERMISSION_REQUESTED_KEY, true).apply()
            currentActivity.requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                POST_NOTIFICATIONS_REQUEST_CODE,
            )
        }
        result.success(null)
    }

    private fun openNotificationSettings(result: MethodChannel.Result) {
        val currentActivity = activity ?: run {
            result.error(
                "activity_unavailable",
                "Notification settings require a foreground activity.",
                null,
            )
            return
        }
        val action = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Settings.ACTION_APP_NOTIFICATION_SETTINGS
        } else {
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS
        }
        val intent = Intent(action).apply {
            data = Uri.parse("package:${context.packageName}")
            putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        }
        try {
            currentActivity.startActivity(intent)
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.success(false)
        }
    }

    private fun showNotification(arguments: Any?, result: MethodChannel.Result) {
        val payload = arguments as? Map<*, *> ?: run {
            result.error("invalid_arguments", "Expected a validated notification envelope.", null)
            return
        }
        val envelope = BuzzNotificationEnvelope.fromTrustedFields(
            eventId = payload["eventId"] as? String ?: "",
            communityId = payload["communityId"] as? String ?: "",
            channelId = payload["channelId"] as? String ?: "",
        ) ?: run {
            result.error("invalid_arguments", "Expected bounded notification IDs.", null)
            return
        }
        try {
            result.success(renderer.render(envelope))
        } catch (error: BuzzNotificationPersistenceException) {
            result.error("native_error", error.message, null)
        } catch (error: BuzzNotificationDeliveryException) {
            result.error("native_error", error.message, null)
        } catch (error: Exception) {
            result.error("native_error", error.message, null)
        }
    }

    private fun takePendingNotificationResponse(result: MethodChannel.Result) {
        if (activity == null) {
            // A headless engine must never consume a response intended for the
            // UI isolate. The response remains buffered for the next Activity.
            result.error(
                "activity_unavailable",
                "Notification responses are available only to the foreground UI.",
                null,
            )
            return
        }
        synchronized(BuzzNotificationProcessLock.value) {
            result.success(responseBuffer.take()?.flutterArguments())
        }
    }

    private fun syncPushSnapshot(arguments: Any?, strict: Boolean, result: MethodChannel.Result) {
        val payload = arguments as? Map<*, *> ?: run {
            result.error("invalid_arguments", "Expected a community push snapshot.", null)
            return
        }
        if (payload["section"] != "communities") {
            result.error("invalid_arguments", "Expected the communities snapshot section.", null)
            return
        }
        if (strict && payload["settleFence"] !is Boolean) {
            result.error("invalid_arguments", "Expected the age-gate settle fence.", null)
            return
        }
        val communities = payload["communities"] as? List<*> ?: run {
            result.error("invalid_arguments", "Expected a bounded community list.", null)
            return
        }
        if (communities.size > MAX_COMMUNITIES) {
            result.error("invalid_arguments", "The community snapshot is too large.", null)
            return
        }

        val allowed = linkedSetOf<String>()
        for (entry in communities) {
            val community = entry as? Map<*, *> ?: run {
                result.error("invalid_arguments", "Expected community records.", null)
                return
            }
            val id = community["id"] as? String
            if (id == null || !BuzzNotificationEnvelope.isValidIdentifier(id)) {
                result.error("invalid_arguments", "Expected bounded community IDs.", null)
                return
            }
            allowed += id
        }

        synchronized(BuzzNotificationProcessLock.value) {
            val previous = snapshotStore.allowedCommunityIds()
            if (!snapshotStore.replaceAllowedCommunityIds(allowed)) {
                result.error("snapshot_sync_failed", "Unable to persist the push snapshot.", null)
                return
            }
            val removed = previous - allowed
            try {
                val removedTargets = pendingStore.removeCommunities(removed)
                    ?: throw IllegalStateException("Unable to purge removed notification targets.")
                if (!dedupStore.removeCommunities(removed)) {
                    throw IllegalStateException("Unable to purge removed notification history.")
                }
                val manager = context.getSystemService(NotificationManager::class.java)
                removedTargets.forEach { envelope ->
                    manager.cancel(buzzNotificationIdFor(envelope))
                }
                responseBuffer.removeCommunities(removed)
                result.success(null)
            } catch (error: Exception) {
                // The persisted allowlist already excludes removed communities;
                // future renders remain blocked while the caller retries cleanup.
                result.error("snapshot_sync_failed", "Unable to purge removed communities.", error.message)
            }
        }
    }

    private fun purgeAgeRestrictedNotifications(result: MethodChannel.Result) {
        synchronized(BuzzNotificationProcessLock.value) {
            if (!restrictionFence.restrict()) {
                result.error(
                    "age_restriction_purge_failed",
                    "Unable to persist notification restriction.",
                    null,
                )
                return
            }
            try {
                context.getSystemService(NotificationManager::class.java).cancelAll()
                if (!pendingStore.clear()) {
                    throw IllegalStateException("Unable to clear pending notification targets.")
                }
                responseBuffer.clear()
                result.success(null)
            } catch (error: Exception) {
                // The fence remains set, so a failed cleanup cannot re-enable
                // future notification presentation.
                result.error(
                    "age_restriction_purge_failed",
                    "Unable to suppress and purge restricted notifications.",
                    error.message,
                )
            }
        }
    }

    private fun restoreAgeRestrictedNotifications(result: MethodChannel.Result) {
        synchronized(BuzzNotificationProcessLock.value) {
            if (!restrictionFence.restore()) {
                result.error(
                    "age_restriction_restore_failed",
                    "Unable to persist notification restoration.",
                    null,
                )
                return
            }
            result.success(null)
        }
    }

    private fun deliverWarmResponse(envelope: BuzzNotificationEnvelope) {
        val methodChannel = channel ?: return
        methodChannel.invokeMethod(
            "notificationOpened",
            envelope.flutterArguments(),
            object : MethodChannel.Result {
                override fun success(response: Any?) {
                    if (response == "handled") responseBuffer.removeIfMatching(envelope)
                }

                override fun error(code: String, message: String?, details: Any?) = Unit

                override fun notImplemented() = Unit
            },
        )
    }

    companion object {
        const val NOTIFICATION_TOKEN_EXTRA = "buzz.notification.token"
        const val OPEN_NOTIFICATION_ACTION = "xyz.block.buzz.mobile.OPEN_NOTIFICATION"

        private const val CHANNEL_NAME = "buzz/push"
        private const val PENDING_STORE_NAME = "buzz.notification.targets"
        private const val PREFERENCES_NAME = "buzz.push"
        private const val DEDUP_PREFERENCES_NAME = "buzz.push.dedup"
        private const val PERMISSION_REQUESTED_KEY = "post_notifications_requested"
        private const val POST_NOTIFICATIONS_REQUEST_CODE = 4217
        private const val MAX_COMMUNITIES = 256
    }
}

internal class BuzzPendingNotificationResponseBuffer {
    private var pending: BuzzNotificationEnvelope? = null

    @Synchronized
    fun record(envelope: BuzzNotificationEnvelope) {
        pending = envelope
    }

    @Synchronized
    fun take(): BuzzNotificationEnvelope? {
        val current = pending
        pending = null
        return current
    }

    @Synchronized
    fun removeIfMatching(expected: BuzzNotificationEnvelope) {
        if (pending == expected) pending = null
    }

    @Synchronized
    fun clear() {
        pending = null
    }

    @Synchronized
    fun removeCommunities(communityIds: Set<String>) {
        if (pending?.communityId?.let { it in communityIds } == true) pending = null
    }
}
