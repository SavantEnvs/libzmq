/* SPDX-License-Identifier: MPL-2.0 */

// Sends one group + body message through a ZMQ_RADIO socket connected to a udp:// endpoint, the
// public path to udp_engine_t::out_event(). The input picks the group, the body size (any 16-bit size,
// past the engine's 8192-byte MAX_UDP_MSG buffer) and the body bytes (the rest of the input, zero-padded).
#ifndef ZMQ_BUILD_DRAFT_API
#define ZMQ_BUILD_DRAFT_API
#endif

#include <fuzzer/FuzzedDataProvider.h>

#include <string.h>
#include <vector>

#include "testutil.hpp"
#include "testutil_unity.hpp"

extern "C" int LLVMFuzzerTestOneInput (const uint8_t *data, size_t size)
{
    FuzzedDataProvider provider (data, size);

    char group[ZMQ_GROUP_MAX_LENGTH + 1];
    memset (group, 0, sizeof group);
    const size_t group_len =
      provider.ConsumeIntegralInRange<size_t> (0, ZMQ_GROUP_MAX_LENGTH);
    const std::vector<uint8_t> group_bytes =
      provider.ConsumeBytes<uint8_t> (group_len);
    if (!group_bytes.empty ())
        memcpy (group, &group_bytes[0], group_bytes.size ());

    const size_t body_len = provider.ConsumeIntegral<uint16_t> ();
    std::vector<uint8_t> body = provider.ConsumeBytes<uint8_t> (body_len);
    body.resize (body_len);

    setup_test_context ();
    void *radio = test_context_socket (ZMQ_RADIO);

    if (zmq_connect (radio, "udp://127.0.0.1:5556") == 0) {
        zmq_msg_t msg;
        if (zmq_msg_init_size (&msg, body_len) == 0) {
            if (body_len > 0)
                memcpy (zmq_msg_data (&msg), &body[0], body_len);
            if (zmq_msg_set_group (&msg, group) != 0
                || zmq_msg_send (&msg, radio, 0) < 0)
                zmq_msg_close (&msg);
        }
    }

    //  Close with the default (infinite) linger: terminating the context waits until the I/O thread
    //  has pulled the queued message into the UDP engine, so out_event() has run for this input.
    test_context_socket_close (radio);
    teardown_test_context ();

    return 0;
}
