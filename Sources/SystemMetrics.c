#include "SystemMetrics.h"

#include <errno.h>
#include <mach/mach.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_types.h>
#include <net/route.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <time.h>

enum { MT_MAX_INTERFACES = 128 };

typedef struct {
    unsigned int index;
    char name[IF_NAMESIZE];
    uint64_t incoming;
    uint64_t outgoing;
} MTInterface;

typedef struct {
    MTInterface interfaces[MT_MAX_INTERFACES];
    size_t count;
    struct timespec time;
} MTNetworkSnapshot;

static pthread_mutex_t mt_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint32_t mt_previous_ticks[CPU_STATE_MAX];
static int mt_cpu_baseline;
static MTNetworkSnapshot mt_previous_network;
static int mt_network_baseline;

static int mt_read_cpu(uint32_t ticks[CPU_STATE_MAX]) {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t result = host_statistics(host, HOST_CPU_LOAD_INFO,
                                         (host_info_t)&info, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS || count != HOST_CPU_LOAD_INFO_COUNT) {
        return 0;
    }
    for (size_t i = 0; i < CPU_STATE_MAX; ++i) {
        ticks[i] = (uint32_t)info.cpu_ticks[i];
    }
    return 1;
}

static int mt_interface_compare(const void *left, const void *right) {
    const MTInterface *a = left;
    const MTInterface *b = right;
    return (a->index > b->index) - (a->index < b->index);
}

static int mt_is_en_interface(const char *name, size_t length) {
    if (length < 3 || length >= IF_NAMESIZE ||
        name[0] != 'e' || name[1] != 'n') {
        return 0;
    }
    for (size_t i = 2; i < length; ++i) {
        if (name[i] < '0' || name[i] > '9') {
            return 0;
        }
    }
    return 1;
}

/* Walk the message's address bitmask instead of assuming the link address is
 * first. A malformed/truncated routing message invalidates the whole sample. */
static int mt_read_interface(const unsigned char *message, size_t length,
                             const struct if_msghdr2 *header,
                             MTNetworkSnapshot *snapshot) {
    if ((header->ifm_flags & (IFF_UP | IFF_RUNNING)) !=
        (IFF_UP | IFF_RUNNING) || header->ifm_data.ifi_type != IFT_ETHER) {
        return 1;
    }
    size_t offset = sizeof(*header);
    for (unsigned int bit = 0; bit < RTAX_MAX; ++bit) {
        if (!((unsigned int)header->ifm_addrs & (1U << bit))) {
            continue;
        }
        if (length - offset < offsetof(struct sockaddr, sa_data)) {
            return 0;
        }
        const struct sockaddr *address =
            (const struct sockaddr *)(const void *)(message + offset);
        size_t address_length = address->sa_len;
        size_t padded = address_length == 0 ? sizeof(uint32_t) :
            (address_length + sizeof(uint32_t) - 1) &
                ~(sizeof(uint32_t) - 1);
        if (padded > length - offset || address_length > length - offset) {
            return 0;
        }
        if (bit == RTAX_IFP && address->sa_family == AF_LINK) {
            const struct sockaddr_dl *link =
                (const struct sockaddr_dl *)(const void *)address;
            size_t name_offset = offsetof(struct sockaddr_dl, sdl_data);
            if (address_length < name_offset ||
                link->sdl_nlen > address_length - name_offset) {
                return 0;
            }
            size_t name_length = link->sdl_nlen;
            if (!mt_is_en_interface(link->sdl_data, name_length)) {
                return 1;
            }
            if (snapshot->count == MT_MAX_INTERFACES) {
                return 0;
            }
            MTInterface *entry = &snapshot->interfaces[snapshot->count++];
            entry->index = header->ifm_index;
            memcpy(entry->name, link->sdl_data, name_length);
            entry->name[name_length] = '\0';
            entry->incoming = header->ifm_data.ifi_ibytes;
            entry->outgoing = header->ifm_data.ifi_obytes;
            return 1;
        }
        offset += padded;
    }
    return 1;
}

static int mt_read_network(MTNetworkSnapshot *snapshot) {
    int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    unsigned char *buffer = NULL;
    size_t length = 0;
    int success = 0;
    memset(snapshot, 0, sizeof(*snapshot));
    for (int attempt = 0; attempt < 3; ++attempt) {
        if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0) {
            goto cleanup;
        }
        if (length == 0) {
            success = 1;
            goto timestamp;
        }
        buffer = malloc(length);
        if (!buffer) {
            goto cleanup;
        }
        if (sysctl(mib, 6, buffer, &length, NULL, 0) == 0) {
            success = 1;
            break;
        }
        int saved_errno = errno;
        free(buffer);
        buffer = NULL;
        if (saved_errno != ENOMEM) {
            goto cleanup;
        }
    }
    if (!success) {
        goto cleanup;
    }
    size_t offset = 0;
    while (offset < length) {
        /* All routing messages begin with length, version and type. */
        if (length - offset < 4) {
            success = 0;
            goto cleanup;
        }
        uint16_t message_length;
        memcpy(&message_length, buffer + offset, sizeof(message_length));
        if (message_length < 4 || message_length > length - offset) {
            success = 0;
            goto cleanup;
        }
        if (buffer[offset + 3] == RTM_IFINFO2) {
            struct if_msghdr2 header;
            if (message_length < sizeof(header)) {
                success = 0;
                goto cleanup;
            }
            memcpy(&header, buffer + offset, sizeof(header));
            if (!mt_read_interface(buffer + offset, message_length,
                                   &header, snapshot)) {
                success = 0;
                goto cleanup;
            }
        }
        offset += message_length;
    }
    qsort(snapshot->interfaces, snapshot->count,
          sizeof(snapshot->interfaces[0]), mt_interface_compare);
timestamp:
    if (clock_gettime(CLOCK_MONOTONIC, &snapshot->time) != 0) {
        success = 0;
    }
cleanup:
    free(buffer);
    return success;
}

MTSystemMetrics mt_system_metrics_sample(void) {
    MTSystemMetrics metrics = {0};
    pthread_mutex_lock(&mt_mutex);

    uint32_t ticks[CPU_STATE_MAX];
    if (mt_read_cpu(ticks)) {
        if (mt_cpu_baseline) {
            uint64_t total = 0;
            uint64_t idle = 0;
            for (size_t i = 0; i < CPU_STATE_MAX; ++i) {
                /* The kernel's 32-bit CPU counters wrap naturally. */
                uint32_t delta = ticks[i] - mt_previous_ticks[i];
                total += delta;
                if (i == CPU_STATE_IDLE) {
                    idle = delta;
                }
            }
            if (total > 0) {
                metrics.cpu_usage_percent =
                    100.0 * (double)(total - idle) / (double)total;
                metrics.cpu_valid = 1;
            }
        }
        memcpy(mt_previous_ticks, ticks, sizeof(ticks));
        mt_cpu_baseline = 1;
    } else {
        mt_cpu_baseline = 0;
    }

    MTNetworkSnapshot network;
    if (mt_read_network(&network)) {
        metrics.interface_count = (int)network.count;
        if (mt_network_baseline && network.count > 0 &&
            network.count == mt_previous_network.count) {
            double elapsed =
                (double)(network.time.tv_sec - mt_previous_network.time.tv_sec) +
                (double)(network.time.tv_nsec - mt_previous_network.time.tv_nsec) /
                    1000000000.0;
            double incoming = 0;
            double outgoing = 0;
            int stable = elapsed > 0;
            for (size_t i = 0; i < network.count && stable; ++i) {
                const MTInterface *current = &network.interfaces[i];
                const MTInterface *previous = &mt_previous_network.interfaces[i];
                if (current->index != previous->index ||
                    strcmp(current->name, previous->name) != 0 ||
                    current->incoming < previous->incoming ||
                    current->outgoing < previous->outgoing) {
                    stable = 0;
                    break;
                }
                incoming += (double)(current->incoming - previous->incoming);
                outgoing += (double)(current->outgoing - previous->outgoing);
            }
            if (stable) {
                metrics.download_bytes_per_second = incoming / elapsed;
                metrics.upload_bytes_per_second = outgoing / elapsed;
                metrics.network_valid = 1;
            }
        }
        mt_previous_network = network;
        mt_network_baseline = 1;
    } else {
        mt_network_baseline = 0;
    }

    pthread_mutex_unlock(&mt_mutex);
    return metrics;
}
