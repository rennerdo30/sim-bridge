package app.simbridge.sim_bridge

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The dial validator has to do two jobs at once: refuse control codes, and
 * still accept the way people and contact cards actually write numbers. The
 * app ships German localization, where `030 / 12345678` is ordinary.
 */
class DialableTest {
    @Test
    fun `accepts real numbers in common formats`() {
        val accepted = listOf(
            "+4915112345678",
            "+49 151 1234 5678",
            "030 / 12345678",
            "+49 30 / 1234 5678",
            "(030) 1234-5678",
            "+1 (800) 555-1234",
            "+41 44 668 18 00",
            "0151.1234.5678",
            "+49 1511234567",
            "911",
            "+18005551234,,123",
            "+18005551234;456",
        )
        for (number in accepted) {
            assertTrue("should accept: $number", isDialable(number))
        }
    }

    @Test
    fun `refuses MMI and USSD control sequences`() {
        val refused = listOf(
            "**21*1234567#",
            "*100#",
            "*#06#",
            "#31#+4915112345678",
            "*21#",
            "+4915112345678#",
        )
        for (number in refused) {
            assertFalse("should refuse: $number", isDialable(number))
        }
    }

    @Test
    fun `refuses malformed or empty input`() {
        val refused = listOf(
            "",
            "   ",
            "abc",
            "12",
            "+",
            "++4915112345678",
            "+49151123456789012345",
            "tel:+4915112345678",
            "+49 151 1234 5678 <script>",
        )
        for (number in refused) {
            assertFalse("should refuse: $number", isDialable(number))
        }
    }
}
