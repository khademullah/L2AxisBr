/* Offline pcap + BPF. The bridge model lives in l2_model.c.
 * Fingerprint matches pkt_l2_obs: fp = 0; for each wire byte,
 * fp = rol1(fp) ^ byte.
 */
#include <stdio.h>
#include <pcap.h>
#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif

static pcap_t *handle;
static struct pcap_pkthdr header;
static const u_char *packet_data;
static int current_byte_idx;

static struct bpf_program bpf_prog;
static int bpf_on;
static int bpf_skip;
static int bpf_match;
static unsigned int pkt_fp;

static unsigned int rol1(unsigned int f)
{
    return (f << 1) | (f >> 31);
}

static void fold_fp(void)
{
    int i, n;

    pkt_fp = 0;
    if (!packet_data)
        return;
    n = (int)header.caplen;
    for (i = 0; i < n; i++)
        pkt_fp = rol1(pkt_fp) ^ packet_data[i];
}

int open_pcap(const char *filename)
{
    char errbuf[PCAP_ERRBUF_SIZE];

    handle = pcap_open_offline(filename, errbuf);
    if (handle == NULL) {
        fprintf(stderr, "Error opening PCAP file: %s\n", errbuf);
        return -1;
    }
    printf("[C-DPI] Successfully opened %s\n", filename);
    return 0;
}

int fetch_next_packet(void)
{
    if (!handle)
        return 0;
    while (1) {
        packet_data = pcap_next(handle, &header);
        if (packet_data == NULL) {
            current_byte_idx = 0;
            pkt_fp = 0;
            return 0;
        }
        if (bpf_on && pcap_offline_filter(&bpf_prog, &header, packet_data) == 0) {
            bpf_skip++;
            continue;
        }
        break;
    }
    current_byte_idx = 0;
    bpf_match++;
    fold_fp();
    return (int)header.caplen;
}

int set_pcap_filter(const char *filter)
{
    if (!handle || !filter || filter[0] == '\0')
        return -1;
    if (bpf_on) {
        pcap_freecode(&bpf_prog);
        bpf_on = 0;
    }
    if (pcap_compile(handle, &bpf_prog, filter, 1, PCAP_NETMASK_UNKNOWN) < 0) {
        fprintf(stderr, "BPF compile failed: %s\n", pcap_geterr(handle));
        return -1;
    }
    bpf_on = 1;
    bpf_skip = 0;
    bpf_match = 0;
    printf("[C-DPI] BPF filter: %s\n", filter);
    return 0;
}

int get_bpf_match(void)
{
    return bpf_match;
}

int get_bpf_skip(void)
{
    return bpf_skip;
}

int get_wire_len(void)
{
    return packet_data ? (int)header.len : 0;
}

long long get_ts_sec(void)
{
    return packet_data ? (long long)header.ts.tv_sec : 0;
}

int get_ts_usec(void)
{
    return packet_data ? (int)header.ts.tv_usec : 0;
}

int get_datalink(void)
{
    return handle ? pcap_datalink(handle) : -1;
}

int get_packet_byte(void)
{
    if (!packet_data || current_byte_idx >= (int)header.caplen)
        return 0;
    return (int)packet_data[current_byte_idx++];
}

unsigned int get_fingerprint(void)
{
    return pkt_fp;
}

void close_pcap(void)
{
    if (bpf_on) {
        pcap_freecode(&bpf_prog);
        bpf_on = 0;
    }
    if (handle) {
        pcap_close(handle);
        handle = NULL;
    }
    packet_data = NULL;
}

#ifdef __cplusplus
}
#endif
