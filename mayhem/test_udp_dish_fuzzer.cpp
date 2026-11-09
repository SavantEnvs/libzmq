/* Fuzzes libzmq's UDP engine through the public API: a ZMQ_DISH socket bound to a UDP endpoint
   receives the fuzz input as one datagram, exactly as a remote peer's packet would arrive. */
#define ZMQ_BUILD_DRAFT_API
#include <zmq.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

//  Largest payload of an IPv4 UDP datagram; a bigger input cannot be sent at all.
static const size_t MAX_DATAGRAM = 65507;

//  Datagram in the DISH wire format: <group size byte><group><body>.
static ssize_t send_packet (int fd, const sockaddr_in &to, const char *group,
                            const char *body)
{
    char buf[64];
    const size_t gl = strlen (group), bl = strlen (body);
    buf[0] = static_cast<char> (gl);
    memcpy (buf + 1, group, gl);
    memcpy (buf + 1 + gl, body, bl);
    return sendto (fd, buf, 1 + gl + bl, 0,
                   reinterpret_cast<const sockaddr *> (&to), sizeof to);
}

//  Receive until a message of group "MARK" carrying `body` arrives, or the receive times out.
static bool recv_marker (void *dish, const char *body)
{
    for (;;) {
        zmq_msg_t msg;
        zmq_msg_init (&msg);
        if (zmq_msg_recv (&msg, dish, 0) < 0) {
            zmq_msg_close (&msg);
            return false;
        }
        const bool hit = strcmp (zmq_msg_group (&msg), "MARK") == 0
                         && zmq_msg_size (&msg) == strlen (body)
                         && memcmp (zmq_msg_data (&msg), body, strlen (body)) == 0;
        zmq_msg_close (&msg);
        if (hit)
            return true;
    }
}

extern "C" int LLVMFuzzerTestOneInput (const uint8_t *data, size_t size)
{
    //  An empty datagram has no group size byte; the engine would read a stale buffer byte.
    if (size == 0 || size > MAX_DATAGRAM)
        return -1;

    //  Pick a free loopback UDP port for the DISH to bind.
    sockaddr_in to;
    memset (&to, 0, sizeof to);
    to.sin_family = AF_INET;
    to.sin_addr.s_addr = htonl (INADDR_LOOPBACK);
    const int probe = socket (AF_INET, SOCK_DGRAM, 0);
    if (probe < 0)
        abort ();
    socklen_t tolen = sizeof to;
    if (bind (probe, reinterpret_cast<sockaddr *> (&to), sizeof to) != 0
        || getsockname (probe, reinterpret_cast<sockaddr *> (&to), &tolen) != 0)
        abort ();
    close (probe);

    void *ctx = zmq_ctx_new ();
    void *dish = zmq_socket (ctx, ZMQ_DISH);
    if (!ctx || !dish)
        abort ();
    const int linger = 0;
    zmq_setsockopt (dish, ZMQ_LINGER, &linger, sizeof linger);
    const int rcvtimeo = 20;
    zmq_setsockopt (dish, ZMQ_RCVTIMEO, &rcvtimeo, sizeof rcvtimeo);
    if (zmq_join (dish, "MARK") != 0)
        abort ();

    char endpoint[64];
    snprintf (endpoint, sizeof endpoint, "udp://127.0.0.1:%u",
              static_cast<unsigned> (ntohs (to.sin_port)));
    const int fd = socket (AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        abort ();

    //  The engine binds its UDP socket on the I/O thread: send "ready" markers until one is delivered.
    bool ready = false;
    if (zmq_bind (dish, endpoint) == 0) {
        for (int i = 0; i < 100 && !ready; i++) {
            send_packet (fd, to, "MARK", "ready");
            ready = recv_marker (dish, "ready");
        }
    }
    if (ready) {
        sendto (fd, data, size, 0, reinterpret_cast<sockaddr *> (&to), sizeof to);
        //  Datagrams are handled in order, so once "done" arrives the input has been processed.
        send_packet (fd, to, "MARK", "done");
        const int wait = 2000;
        zmq_setsockopt (dish, ZMQ_RCVTIMEO, &wait, sizeof wait);
        recv_marker (dish, "done");
    }

    close (fd);
    zmq_close (dish);
    zmq_ctx_term (ctx);
    return 0;
}
