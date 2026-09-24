package xyz.block.buzz.androidpush

import android.content.SharedPreferences
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BuzzNotificationStateTest {
    @Test
    fun restrictionAndSnapshotStateSurviveReconstruction() {
        val preferences = InMemoryPreferences()
        val fence = BuzzNotificationRestrictionFence(preferences)
        val snapshot = BuzzPushSnapshotStore(preferences)

        assertTrue(fence.restrict())
        assertTrue(BuzzNotificationRestrictionFence(preferences).isRestricted())
        assertTrue(snapshot.replaceAllowedCommunityIds(setOf("community-a")))
        assertTrue(
            BuzzPushSnapshotStore(preferences).allowedCommunityIds() == setOf("community-a"),
        )
        assertTrue(fence.restore())
        assertFalse(BuzzNotificationRestrictionFence(preferences).isRestricted())
    }

    @Test
    fun deduplicationIsDurableAndCommunityRemovalClearsIt() {
        val preferences = InMemoryPreferences()
        val store = BuzzNotificationDedupStore(preferences)
        val first = requireNotNull(
            BuzzNotificationEnvelope.fromTrustedFields("event-1", "community-a", "channel"),
        )
        val second = requireNotNull(
            BuzzNotificationEnvelope.fromTrustedFields("event-2", "community-b", "channel"),
        )

        assertFalse(store.contains(first))
        assertTrue(store.record(first))
        assertTrue(BuzzNotificationDedupStore(preferences).contains(first))
        assertFalse(store.record(first))
        assertTrue(store.record(second))
        assertTrue(store.removeCommunities(setOf("community-a")))
        assertFalse(store.contains(first))
        assertTrue(store.contains(second))
    }

    @Test
    fun expiredPendingTargetIsRejectedAndConsumed() {
        val preferences = InMemoryPreferences()
        val token = "550e8400-e29b-41d4-a716-446655440000"
        preferences.putRaw(
            "target_$token",
            "{\"createdAtMillis\":${System.currentTimeMillis() - 25L * 60L * 60L * 1000L}," +
                "\"eventId\":\"event\",\"communityId\":\"community\",\"channelId\":\"channel\"}",
        )

        assertNull(BuzzNotificationPendingStore(preferences).consume(token))
        assertFalse(preferences.contains("target_$token"))
    }

    private class InMemoryPreferences : SharedPreferences {
        private val values = mutableMapOf<String, Any?>()

        override fun getAll(): MutableMap<String, *> = values.toMutableMap()
        override fun getString(key: String, defValue: String?): String? =
            values[key] as? String ?: defValue
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
            (values[key] as? Set<*>)?.filterIsInstance<String>()?.toMutableSet() ?: defValues
        override fun getInt(key: String, defValue: Int): Int = values[key] as? Int ?: defValue
        override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = values[key] as? Float ?: defValue
        override fun getBoolean(key: String, defValue: Boolean): Boolean =
            values[key] as? Boolean ?: defValue
        override fun contains(key: String): Boolean = values.containsKey(key)
        override fun edit(): SharedPreferences.Editor = Editor()
        override fun registerOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener,
        ) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener,
        ) = Unit

        fun putRaw(key: String, value: String) {
            edit().putString(key, value).commit()
        }

        private inner class Editor : SharedPreferences.Editor {
            private val changes = mutableMapOf<String, Any?>()
            private var clear = false

            override fun putString(key: String, value: String?): SharedPreferences.Editor =
                put(key, value)
            override fun putStringSet(
                key: String,
                values: MutableSet<String>?,
            ): SharedPreferences.Editor = put(key, values?.toMutableSet())
            override fun putInt(key: String, value: Int): SharedPreferences.Editor = put(key, value)
            override fun putLong(key: String, value: Long): SharedPreferences.Editor = put(key, value)
            override fun putFloat(key: String, value: Float): SharedPreferences.Editor = put(key, value)
            override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = put(key, value)
            override fun remove(key: String): SharedPreferences.Editor = put(key, null)
            override fun clear(): SharedPreferences.Editor {
                clear = true
                return this
            }
            override fun commit(): Boolean {
                if (clear) values.clear()
                changes.forEach { (key, value) ->
                    if (value == null) values.remove(key) else values[key] = value
                }
                return true
            }
            override fun apply() {
                commit()
            }

            private fun put(key: String, value: Any?): SharedPreferences.Editor {
                changes[key] = value
                return this
            }
        }
    }
}
