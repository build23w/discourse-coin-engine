# frozen_string_literal: true

# v0.11.0 — AES-256-GCM wrapper for storing custodial Solana secret keys.
#
# Key derivation:  PBKDF2-SHA256(passphrase, salt, 200_000 iters, 32 bytes)
# Nonce/IV:        12 random bytes per encryption
# Auth tag:        16 bytes
#
# Passphrase comes from SiteSetting.coin_engine_wallet_encryption_passphrase.
# If unset, encrypt!/decrypt! raise PassphraseMissing — callers handle gracefully.

module DiscourseCoinEngine
  module WalletEncryption
    PBKDF2_ITERATIONS = 200_000
    KEY_LEN           = 32  # AES-256
    IV_LEN            = 12
    AUTH_TAG_LEN      = 16
    SALT_LEN          = 16

    class PassphraseMissing < StandardError; end
    class DecryptFailed     < StandardError; end

    class << self
      def passphrase_set?
        !SiteSetting.coin_engine_wallet_encryption_passphrase.to_s.strip.empty?
      end

      # @param plaintext [String]  64-byte Solana secret key (binary)
      # @return [Hash]              { encrypted_secret:, iv:, auth_tag:, salt: } all binary
      def encrypt!(plaintext)
        raise PassphraseMissing, 'coin_engine_wallet_encryption_passphrase site setting is empty' unless passphrase_set?
        raise ArgumentError, 'plaintext must be a String' unless plaintext.is_a?(String)

        salt = SecureRandom.bytes(SALT_LEN)
        iv   = SecureRandom.bytes(IV_LEN)
        key  = derive_key(salt)

        cipher = OpenSSL::Cipher.new('aes-256-gcm')
        cipher.encrypt
        cipher.key = key
        cipher.iv  = iv
        cipher.auth_data = ''
        ciphertext = cipher.update(plaintext) + cipher.final
        auth_tag   = cipher.auth_tag(AUTH_TAG_LEN)

        {
          encrypted_secret: ciphertext,
          iv:               iv,
          auth_tag:         auth_tag,
          salt:             salt,
        }
      end

      # @param record_or_hash [#encrypted_secret, #iv, #auth_tag, #salt]
      # @return [String] 64-byte binary plaintext secret key
      def decrypt!(record_or_hash)
        raise PassphraseMissing, 'coin_engine_wallet_encryption_passphrase site setting is empty' unless passphrase_set?

        ct  = b(record_or_hash, :encrypted_secret)
        iv  = b(record_or_hash, :iv)
        tag = b(record_or_hash, :auth_tag)
        salt = b(record_or_hash, :salt)
        raise DecryptFailed, 'malformed inputs' if ct.nil? || iv.nil? || tag.nil? || salt.nil?

        key = derive_key(salt)
        cipher = OpenSSL::Cipher.new('aes-256-gcm')
        cipher.decrypt
        cipher.key = key
        cipher.iv  = iv
        cipher.auth_tag = tag
        cipher.auth_data = ''
        cipher.update(ct) + cipher.final
      rescue OpenSSL::Cipher::CipherError => e
        raise DecryptFailed, "AES-GCM decrypt failed: #{e.message}"
      end

      private

      def derive_key(salt)
        OpenSSL::PKCS5.pbkdf2_hmac(
          SiteSetting.coin_engine_wallet_encryption_passphrase.to_s,
          salt,
          PBKDF2_ITERATIONS,
          KEY_LEN,
          'sha256',
        )
      end

      def b(rec, k)
        return rec[k] if rec.is_a?(Hash)
        rec.respond_to?(k) ? rec.public_send(k) : nil
      end
    end
  end
end
