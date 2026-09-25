package xyz.block.buzz.androidpush

import kotlin.test.Test
import kotlin.test.assertEquals

class BuzzNotificationBodyTest {
    @Test
    fun acceptsBoundedVerifiedPreview() {
        assertEquals("Hello from Buzz", buzzNotificationBody(" Hello from Buzz "))
        assertEquals("😀".repeat(180), buzzNotificationBody("😀".repeat(180)))
    }

    @Test
    fun missingOrMalformedPreviewIsGeneric() {
        assertEquals("New message", buzzNotificationBody(null))
        assertEquals("New message", buzzNotificationBody("  "))
        assertEquals("New message", buzzNotificationBody("line\nbreak"))
        assertEquals("New message", buzzNotificationBody("x".repeat(181)))
    }
}
