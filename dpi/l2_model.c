/* Software twin of the MAC table in hdl/pkt_l2br.sv.
 * Learn unicast SA onto the ingress port, then look up DA.
 * Broadcast or I/G multicast floods the other port.
 * DA hit on the ingress port: filter. Hit on the other port: forward.
 * DA miss: flood. Under 12 bytes or over MAX_B: drop, no learn.
 * CAM_N is 1024. First free slot, else replace cam_vic and advance.
 * l2_set_age(0) disables aging. A positive limit expires an entry that
 * many l2_tick() calls after it was learned or refreshed.
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
#define MAX_STD 1518
#define MAX_JUMBO 9000

enum {
    ACT_FILTER = 0,
    ACT_FWD    = 1,
    ACT_FLOOD  = 2,
    ACT_DROP   = 3
};

static int v[CAM_N];
static unsigned long long mac[CAM_N];
static int prt[CAM_N];
static int slot_vid[CAM_N];
static unsigned stamp[CAM_N];
static unsigned now;
static int age_limit;
static int len_mode;
static int mcast_en;
static int vic;

static int len_min(void)
{
    return (len_mode == 0) ? 12 : 64;
}

static int len_max(void)
{
    if (len_mode == 1)
        return MAX_STD;
    if (len_mode == 2)
        return MAX_JUMBO;
    return MAX_B;
}

static int live(int i)
{
    if (!v[i])
        return 0;
    if (age_limit <= 0)
        return 1;
    return (now - stamp[i]) < (unsigned)age_limit;
}

static unsigned long long mac48(long long m)
{
    return (unsigned long long)m & 0xffffffffffffULL;
}

/* I/G is the low bit of the first octet on the wire (bit 40 of the 48-bit value). */
static int is_mcast(unsigned long long m)
{
    return (int)((m >> 40) & 1ULL);
}

static void learn(unsigned long long sa, int port, int vid)
{
    int i;

    sa = mac48((long long)sa);
    if (is_mcast(sa))
        return;
    for (i = 0; i < CAM_N; i++) {
        if (live(i) && mac[i] == sa && slot_vid[i] == vid) {
            prt[i] = port;
            stamp[i] = now;
            return;
        }
    }
    for (i = 0; i < CAM_N; i++) {
        if (!live(i)) {
            v[i] = 1;
            mac[i] = sa;
            slot_vid[i] = vid;
            prt[i] = port;
            stamp[i] = now;
            return;
        }
    }
    v[vic] = 1;
    mac[vic] = sa;
    slot_vid[vic] = vid;
    prt[vic] = port;
    stamp[vic] = now;
    vic = (vic + 1) % CAM_N;
}

static int act_of(unsigned long long da, int port, int vid)
{
    int i;

    da = mac48((long long)da);
    if (da == 0xffffffffffffULL)
        return ACT_FLOOD;
    if (is_mcast(da)) {
        if (mcast_en && da == 0x01005e000001ULL)
            return (port == 1) ? ACT_FILTER : ACT_FWD;
        return ACT_FLOOD;
    }
    for (i = 0; i < CAM_N; i++) {
        if (live(i) && mac[i] == da && slot_vid[i] == vid)
            return (prt[i] == port) ? ACT_FILTER : ACT_FWD;
    }
    return ACT_FLOOD;
}

void l2_set_age(int n)
{
    age_limit = n;
}

void l2_set_len(int mode)
{
    len_mode = mode;
}

void l2_set_mcast(int en)
{
    mcast_en = en;
}

void l2_tick(void)
{
    now++;
}

void l2_reset(void)
{
    int i;

    for (i = 0; i < CAM_N; i++) {
        v[i] = 0;
        mac[i] = 0;
        prt[i] = 0;
        slot_vid[i] = 0;
        stamp[i] = 0;
    }
    now = 0;
    vic = 0;
}

int l2_slot_valid(int i)
{
    if (i < 0 || i >= CAM_N)
        return 0;
    return v[i];
}

long long l2_slot_mac(int i)
{
    if (i < 0 || i >= CAM_N)
        return 0;
    return (long long)mac[i];
}

int l2_slot_port(int i)
{
    if (i < 0 || i >= CAM_N)
        return 0;
    return prt[i];
}

int l2_slot_vid(int i)
{
    if (i < 0 || i >= CAM_N)
        return 0;
    return slot_vid[i];
}

int l2_predict(int port, long long da, long long sa, int nbytes, int vid)
{
    if (nbytes < len_min() || nbytes > len_max())
        return ACT_DROP;
    learn(mac48(sa), port, vid & 0xfff);
    return act_of(mac48(da), port, vid & 0xfff);
}

#ifdef __cplusplus
}
#endif
