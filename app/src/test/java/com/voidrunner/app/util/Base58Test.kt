package com.voidrunner.app.util

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * Seal-time known-vector test for the hand-rolled Base58 codec (KFC-006).
 *
 * The shipped codec had an inverted digit condition in both encode and
 * decode: every multi-byte value collapsed to one or two characters (the
 * mock wallet's 32-byte pubkey displayed as "47" in the v1.0.5 §2.2
 * verdict evidence). These vectors are the published Base58 test set plus
 * the runtime pubkey itself; they fail against the shipped codec and pass
 * against the cured one (algorithm taken verbatim from HAUNT v0.1.14,
 * haunt-lane commit 3a23f2b).
 */
class Base58Test {

    private fun hex(s: String): ByteArray =
        s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    /** Published Base58 vectors (hex in, Base58 out). */
    private val vectors: List<Pair<ByteArray, String>> = listOf(
        ByteArray(0) to "",
        hex("00") to "1",
        hex("0000") to "11",
        hex("00000000000000000000") to "1111111111",
        "Hello World!".toByteArray(Charsets.US_ASCII) to "2NEpo7TZRRrLZSi2U",
        hex("61") to "2g",
        hex("626262") to "a3gV",
        hex("636363") to "aPEr",
        hex("73696d706c792061206c6f6e6720737472696e67") to "2cFupjhnEsSn59qHXstmK2ffpLv2",
        hex("00eb15231dfceb60925886b67d065299925915aeb172c06647") to
            "1NS17iag9jJgTHD1VXjvLCEnZuQ3rJDE9L",
        hex("516b6fcd0f") to "ABnLTmg",
        hex("bf4f89001e670274dd") to "3SEo3LWLoPntC",
        hex("572e4794") to "3EFU7m",
        hex("ecac89cad93923c02321") to "EJDM8drfXA6uyA",
        hex("10c8511e") to "Rt5zm",
        // Full 32-byte input: the all-zero key (Solana System Program id form).
        ByteArray(32) to "11111111111111111111111111111111",
        // Full 32-byte input: the §2.2 mock wallet's pubkey — the exact bytes
        // the shipped codec encoded as "47" on the v1.0.5 Connected screen.
        hex("077f4bc5d6fba524cf178704abe6c695ad9fc6b5b56856b2b7a9ff5064a31eb4") to
            "WGSEgS1wRKJspT4hN8Rw947nX936YdhHRbuqftue9mu",
    )

    @Test
    fun encodeMatchesKnownVectors() {
        for ((raw, expected) in vectors) {
            assertEquals("encode(${raw.toHex()})", expected, Base58.encode(raw))
        }
    }

    @Test
    fun decodeMatchesKnownVectors() {
        for ((raw, encoded) in vectors) {
            assertArrayEquals("decode($encoded)", raw, Base58.decode(encoded))
        }
    }

    @Test
    fun roundTripRandom32ByteInputs() {
        val rng = Random(42)
        repeat(100) {
            val raw = ByteArray(32) { rng.nextInt(256).toByte() }
            assertArrayEquals(raw, Base58.decode(Base58.encode(raw)))
        }
    }

    @Test
    fun encodedPubkeyHasFullLength() {
        // Regression shape for KFC-006: a 32-byte key must encode to a
        // full-length address (32..44 chars), never a collapsed stub.
        val pubkey = hex("077f4bc5d6fba524cf178704abe6c695ad9fc6b5b56856b2b7a9ff5064a31eb4")
        val encoded = Base58.encode(pubkey)
        assertTrue("encoded length ${encoded.length}", encoded.length in 32..44)
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
