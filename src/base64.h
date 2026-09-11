#pragma once

// Standard base64 (RFC 4648) for the payloads that cross the liblogosdelivery
// FFI boundary.
//
// This replaces boost::beast::detail::base64. boost is NOT a declared
// dependency of this module -- it reached the plugin build through the Qt
// backend's propagated inputs, and a Bare module links no Qt. So the include
// simply was not there, and delivery_module could not produce a Bare artifact
// on any platform, mobile or desktop. Forty lines of codec is a smaller thing
// to own than a boost dependency on a phone.
//
// The decoder reproduces boost::beast's contract deliberately: it stops at the
// first character outside the alphabet (padding included) and returns what it
// decoded, rather than throwing. json payloads arriving from the network are
// decoded with it.

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace delivery {

// The one alphabet both directions agree on: base64Decode's lookup table is
// built from it, so the two can never drift apart.
inline constexpr std::string_view kBase64Alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

inline std::string base64Encode(const std::vector<uint8_t>& data) {
    std::string out;
    out.reserve(4 * ((data.size() + 2) / 3));

    size_t i = 0;
    for (; i + 3 <= data.size(); i += 3) {
        const uint32_t chunk =
            (static_cast<uint32_t>(data[i]) << 16) |
            (static_cast<uint32_t>(data[i + 1]) << 8) |
            static_cast<uint32_t>(data[i + 2]);
        out += kBase64Alphabet[(chunk >> 18) & 0x3F];
        out += kBase64Alphabet[(chunk >> 12) & 0x3F];
        out += kBase64Alphabet[(chunk >> 6) & 0x3F];
        out += kBase64Alphabet[chunk & 0x3F];
    }

    const size_t remaining = data.size() - i;
    if (remaining == 1) {
        const uint32_t chunk = static_cast<uint32_t>(data[i]) << 16;
        out += kBase64Alphabet[(chunk >> 18) & 0x3F];
        out += kBase64Alphabet[(chunk >> 12) & 0x3F];
        out += "==";
    } else if (remaining == 2) {
        const uint32_t chunk = (static_cast<uint32_t>(data[i]) << 16) |
                               (static_cast<uint32_t>(data[i + 1]) << 8);
        out += kBase64Alphabet[(chunk >> 18) & 0x3F];
        out += kBase64Alphabet[(chunk >> 12) & 0x3F];
        out += kBase64Alphabet[(chunk >> 6) & 0x3F];
        out += '=';
    }

    return out;
}

inline std::vector<uint8_t> base64Decode(const std::string& encoded) {
    // -1 for everything outside the alphabet, so '=' and whitespace both end
    // the decode the way boost::beast's did.
    static const auto kReverse = [] {
        std::vector<int8_t> table(256, -1);
        for (size_t i = 0; i < kBase64Alphabet.size(); ++i) {
            table[static_cast<uint8_t>(kBase64Alphabet[i])] = static_cast<int8_t>(i);
        }
        return table;
    }();

    std::vector<uint8_t> out;
    out.reserve(encoded.size() / 4 * 3);

    uint32_t accumulator = 0;
    int bits = 0;
    for (const char c : encoded) {
        const int8_t value = kReverse[static_cast<uint8_t>(c)];
        if (value < 0) {
            break;
        }
        accumulator = (accumulator << 6) | static_cast<uint32_t>(value);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.emplace_back(static_cast<uint8_t>((accumulator >> bits) & 0xFF));
        }
    }

    return out;
}

}  // namespace delivery
