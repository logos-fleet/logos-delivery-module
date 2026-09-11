// Unit tests for the module's own base64 codec.
//
// The codec used to be boost::beast::detail::base64, and boost is not a
// declared dependency of this module: it arrived through the Qt plugin
// backend's propagated inputs. A Bare module links no Qt, so the header was
// simply absent and delivery_module could not produce a Bare artifact on ANY
// platform ("fatal error: 'boost/beast/core/detail/base64.hpp' file not
// found"). These tests pin the behaviour the replacement has to reproduce:
// standard base64 with '=' padding, and a decoder that stops at the first
// character outside the alphabet -- which is what boost::beast's did.

#include <logos_test.h>

#include "base64.h"

#include <cstdint>
#include <string>
#include <vector>

namespace {
std::vector<uint8_t> bytes(const std::string& s) {
    return std::vector<uint8_t>(s.begin(), s.end());
}

// LOGOS_ASSERT_EQ streams both sides into the failure message, and a
// std::vector<uint8_t> has no operator<<. Hex keeps the comparison exact and
// the message readable.
std::string hex(const std::vector<uint8_t>& v) {
    static const char* digits = "0123456789abcdef";
    std::string out;
    out.reserve(v.size() * 2);
    for (uint8_t b : v) {
        out += digits[b >> 4];
        out += digits[b & 0x0F];
    }
    return out;
}

std::string decodedHex(const std::string& encoded) {
    return hex(delivery::base64Decode(encoded));
}
}  // namespace

LOGOS_TEST(base64_encodes_the_rfc4648_vectors) {
    LOGOS_ASSERT_EQ(delivery::base64Encode(bytes("")), std::string(""));
    LOGOS_ASSERT_EQ(delivery::base64Encode(bytes("f")), std::string("Zg=="));
    LOGOS_ASSERT_EQ(delivery::base64Encode(bytes("fo")), std::string("Zm8="));
    LOGOS_ASSERT_EQ(delivery::base64Encode(bytes("foo")), std::string("Zm9v"));
    LOGOS_ASSERT_EQ(delivery::base64Encode(bytes("foob")), std::string("Zm9vYg=="));
    LOGOS_ASSERT_EQ(delivery::base64Encode(bytes("fooba")), std::string("Zm9vYmE="));
    LOGOS_ASSERT_EQ(delivery::base64Encode(bytes("foobar")), std::string("Zm9vYmFy"));
}

LOGOS_TEST(base64_decodes_the_rfc4648_vectors) {
    LOGOS_ASSERT_EQ(decodedHex(""), hex(bytes("")));
    LOGOS_ASSERT_EQ(decodedHex("Zg=="), hex(bytes("f")));
    LOGOS_ASSERT_EQ(decodedHex("Zm8="), hex(bytes("fo")));
    LOGOS_ASSERT_EQ(decodedHex("Zm9v"), hex(bytes("foo")));
    LOGOS_ASSERT_EQ(decodedHex("Zm9vYg=="), hex(bytes("foob")));
    LOGOS_ASSERT_EQ(decodedHex("Zm9vYmE="), hex(bytes("fooba")));
    LOGOS_ASSERT_EQ(decodedHex("Zm9vYmFy"), hex(bytes("foobar")));
}

LOGOS_TEST(base64_round_trips_every_byte_value) {
    std::vector<uint8_t> all;
    all.reserve(256);
    for (int i = 0; i < 256; ++i) {
        all.emplace_back(static_cast<uint8_t>(i));
    }
    LOGOS_ASSERT_EQ(decodedHex(delivery::base64Encode(all)), hex(all));
}

LOGOS_TEST(base64_round_trips_all_three_padding_lengths) {
    // 3n, 3n+1 and 3n+2 are the three distinct tail shapes.
    for (size_t n = 0; n < 12; ++n) {
        std::vector<uint8_t> data;
        for (size_t i = 0; i < n; ++i) {
            data.emplace_back(static_cast<uint8_t>(0xA0 + i));
        }
        LOGOS_ASSERT_EQ(decodedHex(delivery::base64Encode(data)), hex(data));
    }
}

LOGOS_TEST(base64_decode_stops_at_the_first_character_outside_the_alphabet) {
    // boost::beast's decoder stopped at anything it did not recognise rather
    // than throwing; the payloads that cross the FFI boundary rely on that.
    LOGOS_ASSERT_EQ(decodedHex("Zm9v*****"), hex(bytes("foo")));
    LOGOS_ASSERT_EQ(decodedHex("Zm9v\nZm9v"), hex(bytes("foo")));
    LOGOS_ASSERT_EQ(decodedHex("!!!!"), hex(bytes("")));
}

LOGOS_TEST(base64_decode_tolerates_a_missing_pad) {
    LOGOS_ASSERT_EQ(decodedHex("Zg"), hex(bytes("f")));
    LOGOS_ASSERT_EQ(decodedHex("Zm8"), hex(bytes("fo")));
}
