package xyz.block.buzz.androidpush

import android.content.SharedPreferences

/** Atomically replaces the communities whose policy allows native rendering. */
internal class BuzzPushSnapshotStore(
    private val preferences: SharedPreferences,
) {
    fun allowedCommunityIds(): Set<String> {
        if (BuzzNotificationProcessLock.snapshotWriteFailed) return emptySet()
        return preferences
            .getStringSet(ALLOWED_COMMUNITIES_KEY, emptySet())
            .orEmpty()
            .toSet()
    }

    fun replaceAllowedCommunityIds(ids: Set<String>): Boolean {
        val committed = preferences.edit()
            .putStringSet(ALLOWED_COMMUNITIES_KEY, ids.toMutableSet())
            .commit()
        BuzzNotificationProcessLock.snapshotWriteFailed = !committed
        return committed
    }

    private companion object {
        const val ALLOWED_COMMUNITIES_KEY = "allowed_community_ids"
    }
}

/** Durable duplicate suppression for already-presented message events. */
internal class BuzzNotificationDedupStore(
    private val preferences: SharedPreferences,
) {
    @Synchronized
    fun contains(envelope: BuzzNotificationEnvelope): Boolean =
        preferences.contains(keyFor(envelope))

    @Synchronized
    fun record(envelope: BuzzNotificationEnvelope): Boolean {
        if (contains(envelope)) return false
        trim()
        return preferences.edit()
            .putLong(keyFor(envelope), System.currentTimeMillis())
            .commit()
    }

    @Synchronized
    fun removeCommunities(communityIds: Set<String>): Boolean {
        if (communityIds.isEmpty()) return true
        val editor = preferences.edit()
        preferences.all.keys
            .filter { key ->
                communityIds.any { id -> key.startsWith("$KEY_PREFIX$id$SEPARATOR") }
            }
            .forEach { key -> editor.remove(key) }
        return editor.commit()
    }

    private fun trim() {
        val entries = preferences.all
            .asSequence()
            .filter { (key, value) -> key.startsWith(KEY_PREFIX) && value is Long }
            .sortedBy { (_, value) -> value as Long }
            .map { (key, _) -> key }
            .toList()
        if (entries.size < MAX_ENTRIES) return
        val editor = preferences.edit()
        entries.take(entries.size - MAX_ENTRIES + 1).forEach { key -> editor.remove(key) }
        editor.commit()
    }

    private fun keyFor(envelope: BuzzNotificationEnvelope): String =
        "$KEY_PREFIX${envelope.communityId}$SEPARATOR${envelope.eventId}"

    private companion object {
        const val KEY_PREFIX = "shown_"
        const val SEPARATOR = "\u0000"
        const val MAX_ENTRIES = 512
    }
}
