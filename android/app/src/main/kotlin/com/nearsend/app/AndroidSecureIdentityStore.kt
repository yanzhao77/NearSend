package com.nearsend.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Stores one encrypted installation identity; the wrapping key never leaves Android Keystore. */
class AndroidSecureIdentityStore(private val context: Context) {
    private val preferences = context.getSharedPreferences(
        "nearsend_secure_identity",
        Context.MODE_PRIVATE,
    )

    fun read(): String? {
        val encoded = preferences.getString(valueKey, null) ?: return null
        val envelope = Base64.decode(encoded, Base64.NO_WRAP)
        require(envelope.size > ivBytes) { "identity envelope is truncated" }
        val iv = envelope.copyOfRange(0, ivBytes)
        val ciphertext = envelope.copyOfRange(ivBytes, envelope.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(tagBits, iv))
        return String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
    }

    fun write(value: String) {
        require(value.isNotEmpty()) { "identity must not be empty" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val ciphertext = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        val envelope = cipher.iv + ciphertext
        val encoded = Base64.encodeToString(envelope, Base64.NO_WRAP)
        check(preferences.edit().putString(valueKey, encoded).commit()) {
            "identity ciphertext could not be committed"
        }
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(keyStoreName).apply { load(null) }
        val existing = keyStore.getKey(keyAlias, null)
        if (existing is SecretKey) return existing

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            keyStoreName,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val keyStoreName = "AndroidKeyStore"
        const val keyAlias = "nearsend.installation.identity.v1"
        const val valueKey = "identity.v1"
        const val ivBytes = 12
        const val tagBits = 128
    }
}
