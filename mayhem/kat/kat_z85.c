/* Known-answer probe: RFC 32 Z85 test vector 86 4F D2 6F B5 59 F7 5B <-> "HelloWorld". */
#include <stdio.h>
#include <string.h>
#include <zmq.h>

int main (void)
{
    const uint8_t data[8] = {0x86, 0x4F, 0xD2, 0x6F, 0xB5, 0x59, 0xF7, 0x5B};
    char enc[11];
    uint8_t dec[8];
    if (!zmq_z85_encode (enc, data, sizeof data))
        return 1;
    if (!zmq_z85_decode (dec, "HelloWorld") || memcmp (dec, data, sizeof data))
        return 1;
    puts (enc);
    return 0;
}
