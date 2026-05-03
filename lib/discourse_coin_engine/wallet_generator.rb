# frozen_string_literal: true

# v0.11.0 — Server-side Solana keypair generation.
#
# Solana keypairs are pure Ed25519. Public key is 32 bytes (Base58-encoded for
# display). The 64-byte "secret key" format used by @solana/web3.js is the
# 32-byte seed concatenated with the 32-byte public key.
#
# Generation strategy (in order):
#   1. OpenSSL >= 3.0 native Ed25519 (most modern Discourse hosts)
#   2. RbNaCl (libsodium binding — usually present on Discourse standalone)
#   3. Raise — caller must shell out or fail gracefully
#
# Used by:
#   - Backfill job (existing users with empty wallet)
#   - Admin "Generate wallet" button
#   - Signup hook fallback when client-side web3.js was unavailable

module DiscourseCoinEngine
  module WalletGenerator
    BASE58_ALPHA = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'.freeze

    class GenerationFailed < StandardError; end

    class << self
      # @return [Hash] { public_key:, secret_key: }  where:
      #   public_key  is a Base58 string (44 chars typical)
      #   secret_key  is a 64-byte binary string (seed || pubkey)
      def generate
        raw = generate_raw
        {
          public_key: base58_encode(raw[:public]),
          secret_key: raw[:seed] + raw[:public],  # 64-byte web3.js format
        }
      end

      def base58_encode(bytes)
        return '' if bytes.nil? || bytes.empty?
        # Treat the byte string as a big-endian integer
        n = bytes.bytes.inject(0) { |a, b| (a << 8) | b }
        out = +''
        while n > 0
          n, rem = n.divmod(58)
          out.prepend(BASE58_ALPHA[rem])
        end
        # Preserve leading zero bytes as '1' characters
        bytes.bytes.take_while(&:zero?).each { out.prepend('1') }
        out
      end

      private

      def generate_raw
        # Strategy 1: OpenSSL 3.0+ native Ed25519
        begin
          key = OpenSSL::PKey.generate_key('ED25519')
          if key.respond_to?(:raw_public_key) && key.respond_to?(:raw_private_key)
            pub  = key.raw_public_key
            seed = key.raw_private_key
            return { public: pub, seed: seed } if pub&.bytesize == 32 && seed&.bytesize == 32
          end
        rescue StandardError => e
          Rails.logger.debug("[coin_engine] OpenSSL Ed25519 unavailable: #{e.class}: #{e.message}")
        end

        # Strategy 2: rbnacl
        begin
          require 'rbnacl'
          signing_key = RbNaCl::SigningKey.generate
          return { public: signing_key.verify_key.to_bytes, seed: signing_key.to_bytes }
        rescue LoadError, StandardError => e
          Rails.logger.debug("[coin_engine] rbnacl unavailable: #{e.class}: #{e.message}")
        end

        raise GenerationFailed, 'no Ed25519 backend available (need OpenSSL >= 3.0 or rbnacl gem)'
      end
    end
  end
end
