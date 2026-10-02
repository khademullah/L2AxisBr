/* Software twin of the MAC table in hdl/pkt_l2br.sv.
 * Learn unicast SA onto the ingress port, then look up DA.
 * Broadcast or I/G multicast floods the other port.
 * DA hit on the ingress port: filter. Hit on the other port: forward.
 * DA miss: flood. Under 12 bytes or over MAX_B: drop, no learn.
 * CAM_N is 1024. First free slot, else replace cam_vic and advance.
 * Port A is 0, port B is 1. Same-cycle commits are not issued by the bench;
 * the RTL still applies A before B if they ever land together.
 */
#include <stdio.h>
#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif

#define CAM_N 1024
#define MAX_B 2048

enum {
    ACT_FILTER = 0,
    ACT_FWD    = 1,
    ACT_FLOOD  = 2,
    ACT_DROP   = 3
};

static int v[CAM_N];
static unsigned long long mac[CAM_N];
static int prt[CAM_N];
static int vic;

static unsigned long long mac48(long long m)
{
    return (unsigned long long)m & 0xffffffffffffULL;
}

/* I/G is the low bit of the first octet on the wire (bit 40 of the 48-bit value). */
static int is_mcast(unsigned long long m)
{
    return (int)((m >> 40) & 1ULL);
}

static void learn(unsigned long long sa, int port)
{
    int i;

    sa = mac48((long long)sa);
    if (is_mcast(sa))
        return;
    for (i = 0; i < CAM_N; i++) {
        if (v[i] && mac[i] == sa) {
            prt[i] = port;
            return;
        }
    }
    for (i = 0; i < CAM_N; i++) {
        if (!v[i]) {
            v[i] = 1;
            mac[i] = sa;
            prt[i] = port;
            return;
        }
    }
    v[vic] = 1;
    mac[vic] = sa;
    prt[vic] = port;
    vic = (vic + 1) % CAM_N;
}

static int act_of(unsigned long long da, int port)
{
    int i;

    da = mac48((long long)da);
    if (da == 0xffffffffffffULL || is_mcast(da))
        return ACT_FLOOD;
    for (i = 0; i < CAM_N; i++) {
        if (v[i] && mac[i] == da)
            return (prt[i] == port) ? ACT_FILTER : ACT_FWD;
    }
    return ACT_FLOOD;
}

void l2_reset(void)
{
    int i;

    for (i = 0; i < CAM_N; i++) {
        v[i] = 0;
        mac[i] = 0;
        prt[i] = 0;
    }
    vic = 0;
}

int l2_predict(int port, long long da, long long sa, int nbytes)
{
    if (nbytes < 12 || nbytes > MAX_B)
        return ACT_DROP;
    learn(mac48(sa), port);
    return act_of(mac48(da), port);
}

#ifdef __cplusplus
}
#endif
