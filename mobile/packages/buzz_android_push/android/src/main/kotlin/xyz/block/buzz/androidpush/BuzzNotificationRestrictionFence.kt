package xyz.block.buzz.androidpush

import android.content.SharedPreferences

/** Persistent, fail-closed notification presentation state for the age gate. */
internal class BuzzNotificationRestrictionFence(
    private val preferences: SharedPreferences,
) {
    fun isRestricted(): Boolean =
        BuzzNotificationProcessLock.restrictionWriteFailed ||
            preferences.getBoolean(RESTRICTED_KEY, false)

    fun restrict(): Boolean = writeRestricted(true).also { committed ->
        if (!committed) BuzzNotificationProcessLock.restrictionWriteFailed = true
    }

    fun restore(): Boolean = writeRestricted(false).also { committed ->
        if (committed) BuzzNotificationProcessLock.restrictionWriteFailed = false
        else BuzzNotificationProcessLock.restrictionWriteFailed = true
    }

    private fun writeRestricted(restricted: Boolean): Boolean = preferences.edit()
        .putBoolean(RESTRICTED_KEY, restricted)
        .commit()

    private companion object {
        const val RESTRICTED_KEY = "age_restricted"
    }
}
