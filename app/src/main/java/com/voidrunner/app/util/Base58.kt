package com.voidrunner.app.util

/**
 * Minimal Base58 (Bitcoin alphabet) encoder.
 *
 * Kept in-tree on purpose: it avoids pulling a whole crypto utility library
 * just to display wallet addresses and signatures.
 */
object Base58 {
    private const val ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    private val INDEXES = IntArray(128) { -1 }.also { table ->
        ALPHABET.forEachIndexed { i, c -> table[c.code] = i }
    }

    fun encode(input: ByteArray): String {
        if (input.isEmpty()) return ""
        // Count leading zero bytes.
        var zeros = 0
        while (zeros < input.size && input[zeros] == 0.toByte()) zeros++
        // Convert base-256 to base-58.
        val encoded = ByteArray(input.size * 2)
        var outputStart = encoded.size
        var inputStart = zeros
        while (inputStart < input.size) {
            var carry = input[inputStart].toInt() and 0xFF
            var i = encoded.size - 1
            while (i >= outputStart || carry != 0) {
                carry += 256 * (if (i >= outputStart) 0 else encoded[i].toInt() and 0xFF)
                encoded[i] = (carry % 58).toByte()
                carry /= 58
                i--
            }
            outputStart = i + 1
            inputStart++
        }
        // Skip leading zeros in the encoded output.
        var k = outputStart
        while (k < encoded.size && encoded[k] == 0.toByte()) k++
        return buildString {
            repeat(zeros) { append('1') }
            for (i in k until encoded.size) append(ALPHABET[encoded[i].toInt() and 0xFF])
        }
    }

    fun decode(input: String): ByteArray {
        if (input.isEmpty()) return ByteArray(0)
        var zeros = 0
        while (zeros < input.length && input[zeros] == '1') zeros++
        val decoded = ByteArray(input.length)
        var outputStart = decoded.size
        for (c in input) {
            val digit = if (c.code < 128) INDEXES[c.code] else -1
            require(digit >= 0) { "Invalid Base58 character: $c" }
            var carry = digit
            var i = decoded.size - 1
            while (i >= outputStart || carry != 0) {
                carry += 58 * (if (i >= outputStart) 0 else decoded[i].toInt() and 0xFF)
                decoded[i] = (carry % 256).toByte()
                carry = carry shr 8
                i--
            }
            outputStart = i + 1
        }
        var k = outputStart
        while (k < decoded.size && decoded[k] == 0.toByte()) k++
        return ByteArray(zeros + (decoded.size - k)).also { out ->
            System.arraycopy(decoded, k, out, zeros, decoded.size - k)
        }
    }
}
