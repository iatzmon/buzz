package xyz.block.buzz.androidpush

/**
 * Coordinates notification policy and delivery across Flutter engines in the
 * same Android process. A plugin instance is created per engine, so an
 * instance lock alone cannot protect shared preferences and notification
 * manager state.
 */
internal object BuzzNotificationProcessLock {
    val value = Any()

    /** Failed policy writes block presentation until their own write succeeds. */
    @Volatile
    var restrictionWriteFailed: Boolean = false

    @Volatile
    var snapshotWriteFailed: Boolean = false
}
