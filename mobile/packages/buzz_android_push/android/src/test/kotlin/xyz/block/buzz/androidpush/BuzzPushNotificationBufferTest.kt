package xyz.block.buzz.androidpush

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class BuzzPushNotificationBufferTest {
    @Test
    fun responseIsOneShot() {
        val buffer = BuzzPendingNotificationResponseBuffer()
        val envelope = requireNotNull(
            BuzzNotificationEnvelope.fromTrustedFields("event", "community", "channel"),
        )

        buffer.record(envelope)

        assertEquals(envelope, buffer.take())
        assertNull(buffer.take())
    }

    @Test
    fun handledResponseRemovesOnlyTheMatchingTarget() {
        val buffer = BuzzPendingNotificationResponseBuffer()
        val first = requireNotNull(
            BuzzNotificationEnvelope.fromTrustedFields("event-1", "community", "channel"),
        )
        val second = requireNotNull(
            BuzzNotificationEnvelope.fromTrustedFields("event-2", "community", "channel"),
        )

        buffer.record(first)
        buffer.removeIfMatching(second)
        assertEquals(first, buffer.take())

        buffer.record(first)
        buffer.removeIfMatching(first)
        assertNull(buffer.take())
    }
}
