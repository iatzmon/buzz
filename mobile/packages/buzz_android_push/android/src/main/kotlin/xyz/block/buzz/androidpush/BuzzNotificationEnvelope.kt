package xyz.block.buzz.androidpush

/**
 * The small, already-validated message envelope needed to render and route a
 * Buzz notification.
 *
 * This type deliberately contains no notification-provider payload fields.
 * A future FCM or self-hosted transport adapter must verify its message and
 * construct this envelope before calling [BuzzNotificationRenderer].
 */
internal class BuzzNotificationEnvelope private constructor(
    val eventId: String,
    val communityId: String,
    val channelId: String,
) {
    fun flutterArguments(): Map<String, String> = mapOf(
        "eventId" to eventId,
        "communityId" to communityId,
        "channelId" to channelId,
    )

    override fun equals(other: Any?): Boolean =
        other is BuzzNotificationEnvelope &&
            eventId == other.eventId &&
            communityId == other.communityId &&
            channelId == other.channelId

    override fun hashCode(): Int =
        31 * (31 * eventId.hashCode() + communityId.hashCode()) + channelId.hashCode()

    companion object {
        private const val MAX_ID_LENGTH = 256

        internal fun isValidIdentifier(value: String): Boolean = validId(value)

        /** Builds an envelope only from fields verified by the transport. */
        fun fromTrustedFields(
            eventId: String,
            communityId: String,
            channelId: String,
        ): BuzzNotificationEnvelope? {
            if (!validId(eventId) || !validId(communityId) || !validId(channelId)) {
                return null
            }
            return BuzzNotificationEnvelope(eventId, communityId, channelId)
        }

        private fun validId(value: String): Boolean {
            return value.isNotEmpty() &&
                value.length <= MAX_ID_LENGTH &&
                value.all { character -> character.code in 0x21..0x7e }
        }
    }
}
