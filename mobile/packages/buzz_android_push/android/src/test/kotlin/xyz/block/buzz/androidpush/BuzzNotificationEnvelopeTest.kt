package xyz.block.buzz.androidpush

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class BuzzNotificationEnvelopeTest {
    @Test
    fun trustedFieldsBecomeOnlyTheNavigationArguments() {
        val envelope = requireNotNull(
            BuzzNotificationEnvelope.fromTrustedFields("event-1", "community-1", "channel-1"),
        )

        assertEquals(
            mapOf(
                "eventId" to "event-1",
                "communityId" to "community-1",
                "channelId" to "channel-1",
            ),
            envelope.flutterArguments(),
        )
    }

    @Test
    fun emptyControlAndOverlongIdsAreRejected() {
        assertNull(BuzzNotificationEnvelope.fromTrustedFields("", "community", "channel"))
        assertNull(
            BuzzNotificationEnvelope.fromTrustedFields(
                "event\nfrom-external-intent",
                "community",
                "channel",
            ),
        )
        assertNull(
            BuzzNotificationEnvelope.fromTrustedFields(
                "e".repeat(257),
                "community",
                "channel",
            ),
        )
    }
}
