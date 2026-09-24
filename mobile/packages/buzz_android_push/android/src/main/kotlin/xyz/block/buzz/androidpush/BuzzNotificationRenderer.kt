package xyz.block.buzz.androidpush

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.Manifest
import android.os.Build
import java.util.UUID

internal object BuzzNotificationChannels {
    const val MESSAGE_CHANNEL_ID = "buzz.messages"

    fun ensure(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                MESSAGE_CHANNEL_ID,
                "Messages",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "New Buzz messages"
                setShowBadge(true)
            },
        )
    }

}

internal fun buzzNotificationIdFor(envelope: BuzzNotificationEnvelope): Int =
    "${envelope.communityId}\u0000${envelope.eventId}".hashCode() and Int.MAX_VALUE

/**
 * Persists one-time notification targets behind an unguessable token.
 * Exported activities receive only this token and recover IDs from this store.
 */
internal class BuzzNotificationPendingStore(
    private val preferences: android.content.SharedPreferences,
) {
    private data class StoredTarget(
        val createdAtMillis: Long,
        val envelope: BuzzNotificationEnvelope,
    ) {
        fun isFresh(nowMillis: Long): Boolean =
            nowMillis - createdAtMillis <= MAX_TARGET_AGE_MILLIS
    }

    fun issue(envelope: BuzzNotificationEnvelope): String? {
        trim()
        val token = UUID.randomUUID().toString()
        val payload = encode(
            StoredTarget(System.currentTimeMillis(), envelope),
        )
        val committed = preferences.edit().putString(keyFor(token), payload).commit()
        return token.takeIf { committed }
    }

    fun consume(token: String): BuzzNotificationEnvelope? {
        if (!UUID_PATTERN.matches(token)) return null
        val key = keyFor(token)
        val payload = preferences.getString(key, null) ?: return null
        val target = decode(payload)
        // A response is one-shot even if the target cannot be decoded.
        preferences.edit().remove(key).commit()
        if (target == null || !target.isFresh(System.currentTimeMillis())) return null
        return target.envelope
    }

    fun clear(): Boolean {
        val editor = preferences.edit()
        preferences.all.keys
            .filter { key -> key.startsWith(KEY_PREFIX) }
            .forEach { key -> editor.remove(key) }
        return editor.commit()
    }

    fun removeCommunities(communityIds: Set<String>): List<BuzzNotificationEnvelope>? {
        if (communityIds.isEmpty()) return emptyList()
        val targets = preferences.all
            .asSequence()
            .filter { (key, value) -> key.startsWith(KEY_PREFIX) && value is String }
            .mapNotNull { (key, value) ->
                decode(value as String)?.let { key to it.envelope }
            }
            .filter { (_, envelope) -> envelope.communityId in communityIds }
            .toList()
        val editor = preferences.edit()
        targets.forEach { (key, _) -> editor.remove(key) }
        return targets.map { (_, envelope) -> envelope }.takeIf { editor.commit() }
    }

    private fun trim() {
        val entries = preferences.all
            .asSequence()
            .filter { (key, value) -> key.startsWith(KEY_PREFIX) && value is String }
            .mapNotNull { (key, value) -> decode(value as String)?.let { key to it.createdAtMillis } }
            .sortedBy { (_, createdAt) -> createdAt }
            .toList()
        if (entries.size < MAX_PENDING_TARGETS) return

        val removeCount = entries.size - MAX_PENDING_TARGETS + 1
        val editor = preferences.edit()
        entries.take(removeCount).forEach { (key, _) -> editor.remove(key) }
        editor.commit()
    }

    private fun encode(target: StoredTarget): String {
        return org.json.JSONObject()
            .put("createdAtMillis", target.createdAtMillis)
            .put("eventId", target.envelope.eventId)
            .put("communityId", target.envelope.communityId)
            .put("channelId", target.envelope.channelId)
            .toString()
    }

    private fun decode(payload: String): StoredTarget? {
        return runCatching {
            val json = org.json.JSONObject(payload)
            val envelope = BuzzNotificationEnvelope.fromTrustedFields(
                eventId = json.getString("eventId"),
                communityId = json.getString("communityId"),
                channelId = json.getString("channelId"),
            ) ?: return null
            StoredTarget(json.getLong("createdAtMillis"), envelope)
        }.getOrNull()
    }

    private fun keyFor(token: String): String = "$KEY_PREFIX$token"

    companion object {
        private const val KEY_PREFIX = "target_"
        private const val MAX_PENDING_TARGETS = 64
        private const val MAX_TARGET_AGE_MILLIS = 24L * 60L * 60L * 1000L
        private val UUID_PATTERN = Regex(
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}",
        )
    }
}

/** Renders generic, privacy-preserving Buzz message notifications. */
internal class BuzzNotificationRenderer(
    private val context: Context,
    private val pendingStore: BuzzNotificationPendingStore =
        BuzzNotificationPendingStore(
            context.getSharedPreferences(PENDING_STORE_NAME, Context.MODE_PRIVATE),
        ),
    private val restrictionFence: BuzzNotificationRestrictionFence =
        BuzzNotificationRestrictionFence(
            context.getSharedPreferences(RESTRICTION_PREFERENCES_NAME, Context.MODE_PRIVATE),
        ),
    private val snapshotStore: BuzzPushSnapshotStore = BuzzPushSnapshotStore(
        context.getSharedPreferences(RESTRICTION_PREFERENCES_NAME, Context.MODE_PRIVATE),
    ),
    private val dedupStore: BuzzNotificationDedupStore = BuzzNotificationDedupStore(
        context.getSharedPreferences(DEDUP_PREFERENCES_NAME, Context.MODE_PRIVATE),
    ),
) {
    fun render(envelope: BuzzNotificationEnvelope): Boolean {
        synchronized(BuzzNotificationProcessLock.value) {
            if (restrictionFence.isRestricted() ||
                envelope.communityId !in snapshotStore.allowedCommunityIds() ||
                dedupStore.contains(envelope)
            ) return false
            BuzzNotificationChannels.ensure(context)
            val manager = context.getSystemService(NotificationManager::class.java)
            if (notificationsSuppressed(manager)) return false
            val token = pendingStore.issue(envelope)
                ?: throw BuzzNotificationPersistenceException(
                    "Unable to persist notification response target.",
                )
            val requestCode = buzzNotificationIdFor(envelope)
            val clickIntent = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.apply {
                    action = BuzzAndroidPushBridge.OPEN_NOTIFICATION_ACTION
                    replaceExtras(android.os.Bundle())
                    addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    putExtra(BuzzAndroidPushBridge.NOTIFICATION_TOKEN_EXTRA, token)
                }
                ?: throw BuzzNotificationDeliveryException(
                    "Unable to resolve the application launch activity.",
                )
            val contentIntent = PendingIntent.getActivity(
                context,
                requestCode,
                clickIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, BuzzNotificationChannels.MESSAGE_CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
                .setSmallIcon(R.drawable.ic_notification_buzz)
                .setContentTitle("Buzz")
                .setContentText("New message")
                .setCategory(Notification.CATEGORY_MESSAGE)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(contentIntent)
                .build()

            try {
                manager.notify(requestCode, notification)
            } catch (error: SecurityException) {
                // Android can revoke POST_NOTIFICATIONS between the check and
                // notify. Treat that race as ordinary policy suppression;
                // retain all other failures for the caller to retry.
                if (notificationsSuppressed(manager)) return false
                throw BuzzNotificationDeliveryException(
                    "Unable to deliver the notification.",
                    error,
                )
            } catch (error: RuntimeException) {
                throw BuzzNotificationDeliveryException(
                    "Unable to deliver the notification.",
                    error,
                )
            }
            if (!dedupStore.record(envelope)) {
                manager.cancel(requestCode)
                throw BuzzNotificationPersistenceException(
                    "Unable to persist notification duplicate suppression.",
                )
            }
            return true
        }
    }

    private fun notificationsSuppressed(manager: NotificationManager): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            !manager.areNotificationsEnabled()
        ) return true
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(BuzzNotificationChannels.MESSAGE_CHANNEL_ID)
                ?.importance == NotificationManager.IMPORTANCE_NONE
    }

    companion object {
        private const val PENDING_STORE_NAME = "buzz.notification.targets"
        private const val RESTRICTION_PREFERENCES_NAME = "buzz.push"
        private const val DEDUP_PREFERENCES_NAME = "buzz.push.dedup"
    }
}

internal class BuzzNotificationPersistenceException(
    message: String,
) : IllegalStateException(message)

internal class BuzzNotificationDeliveryException(
    message: String,
    cause: Throwable? = null,
) : IllegalStateException(message, cause)
