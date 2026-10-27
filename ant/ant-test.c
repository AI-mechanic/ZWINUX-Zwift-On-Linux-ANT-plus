/*
 * ant-test.exe: checks a libusb0.dll the way Zwift's ANT_DLL.dll uses it,
 * against the real ANT+ stick. zwift-ant.sh test runs it.
 *
 * [1] needs no hardware: the exports and the calling convention.
 * [2] runs when a stick is plugged in. It repeats ANT_DLL's own sequence
 *     (usb_device_handle_libusb.cpp in the ANT SDK): list the devices,
 *     read each one's strings, trial-open each one, open the stick, run the
 *     same receive thread, write with usb_interrupt_write() and shut down
 *     the same way. In between it talks ANT to the stick and times it.
 *
 * A Windows program; it loads libusb0.dll by name, as ANT_DLL does. Build
 * it with mingw against libusb-wine's usb.h, whose structures are laid out
 * like libusb-win32's (zwift-ant.sh setup puts the source in ant/src):
 *
 *   x86_64-w64-mingw32-gcc -O2 -Wall -s -Wl,--no-insert-timestamp \
 *       -I ant/src/src -o ant/ant-test.exe ant/ant-test.c
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <windows.h>

/* the Windows headers define interface as struct */
#undef interface
/* usb.h uses the BSD names for its integer types, which mingw lacks */
typedef uint8_t u_int8_t;
typedef uint16_t u_int16_t;
typedef uint32_t u_int32_t;
#include "usb.h"

#define EP_OUT                  0x01
#define EP_IN                   0x81
#define ETRANSFER_TIMEDOUT      116     /* libusb-win32's timeout error */

static int failures;
static int stick_tested;        /* [2] found a stick, so the result covers it */

/* ms_now() only moves every ~16 ms under Wine; time with QPC */
static DWORD ms_now(void)
{
    static LARGE_INTEGER f;
    LARGE_INTEGER c;
    if (!f.QuadPart) QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (DWORD)(c.QuadPart * 1000 / f.QuadPart);
}
#define PASS(...)  do { printf("  PASS  "); printf(__VA_ARGS__); printf("\n"); } while (0)
#define FAIL(...)  do { printf("  FAIL  "); printf(__VA_ARGS__); printf("\n"); failures++; } while (0)
#define INFO(...)  do { printf("        "); printf(__VA_ARGS__); printf("\n"); } while (0)

/* ---- the API, resolved by name the way ANT_DLL does it ------------------- */

#define API(ret, name, args) typedef ret (*name##_t) args; static name##_t p_##name;
API(void, usb_init, (void))
API(void, usb_set_debug, (int))
API(int, usb_find_busses, (void))
API(int, usb_find_devices, (void))
API(struct usb_bus *, usb_get_busses, (void))
API(usb_dev_handle *, usb_open, (struct usb_device *))
API(int, usb_close, (usb_dev_handle *))
API(struct usb_device *, usb_device, (usb_dev_handle *))
API(int, usb_set_configuration, (usb_dev_handle *, int))
API(int, usb_claim_interface, (usb_dev_handle *, int))
API(int, usb_release_interface, (usb_dev_handle *, int))
API(int, usb_clear_halt, (usb_dev_handle *, unsigned int))
API(int, usb_reset, (usb_dev_handle *))
API(int, usb_get_string_simple, (usb_dev_handle *, int, char *, size_t))
API(int, usb_bulk_read, (usb_dev_handle *, int, char *, int, int))
API(int, usb_interrupt_write, (usb_dev_handle *, int, char *, int, int))
API(int, usb_bulk_setup_async, (usb_dev_handle *, void **, unsigned char))
API(int, usb_submit_async, (void *, char *, int))
API(int, usb_reap_async_nocancel, (void *, int))
API(int, usb_cancel_async, (void *))
API(int, usb_free_async, (void **))
API(int, usb_reap_async, (void *, int))
API(const char *, usb_strerror, (void))

static const char *const ant_imports[] = {
    "usb_claim_interface", "usb_get_busses", "usb_clear_halt", "usb_get_string_simple",
    "usb_close", "usb_reset", "usb_init", "usb_find_busses", "usb_find_devices",
    "usb_open", "usb_release_interface", "usb_interrupt_write", "usb_bulk_read",
    "usb_device", "usb_set_configuration", "usb_set_debug", "usb_bulk_setup_async",
    "usb_submit_async", "usb_reap_async_nocancel", "usb_cancel_async", "usb_free_async",
};

static int resolve(HMODULE m)
{
    int missing = 0;
    unsigned i;

    for (i = 0; i < sizeof(ant_imports) / sizeof(ant_imports[0]); i++)
        if (!GetProcAddress(m, ant_imports[i])) {
            FAIL("export missing: %s (ANT_DLL refuses to load without it)", ant_imports[i]);
            missing++;
        }
#define R(name) p_##name = (name##_t)(void (*)(void))GetProcAddress(m, #name)
    R(usb_init); R(usb_set_debug); R(usb_find_busses); R(usb_find_devices);
    R(usb_get_busses); R(usb_open); R(usb_close); R(usb_device);
    R(usb_set_configuration); R(usb_claim_interface); R(usb_release_interface);
    R(usb_clear_halt); R(usb_reset); R(usb_get_string_simple); R(usb_bulk_read);
    R(usb_interrupt_write); R(usb_bulk_setup_async); R(usb_submit_async);
    R(usb_reap_async_nocancel); R(usb_cancel_async); R(usb_free_async);
    R(usb_reap_async); R(usb_strerror);
#undef R
    if (!p_usb_reap_async || !p_usb_strerror) {
        FAIL("usb_reap_async / usb_strerror missing");
        missing++;
    }
    return missing;
}

/* ---- [1] calling convention ---------------------------------------------- */

/*
 * Call fn with chosen values in BOTH conventions' argument registers:
 * rcx/rdx (Microsoft x64, what a Windows caller uses) and rdi/rsi (System V,
 * what a Linux-compiled function reads). Whichever pair the function acts on
 * shows which convention it was built with. Also reports whether rdi and rsi
 * survive: Microsoft x64 makes them callee-saved, System V does not.
 */
struct probe {
    void *fn;                           /* 0  */
    unsigned long long ms1, ms2;        /* 8, 16  */
    unsigned long long sv1, sv2;        /* 24, 32 */
    unsigned long long ret;             /* 40 */
    unsigned long long rdi_after;       /* 48 */
    unsigned long long rsi_after;       /* 56 */
};

static void call_probe(struct probe *p)
{
    __asm__ volatile(
        "mov  %%rsp, %%r12\n\t"
        "and  $-16, %%rsp\n\t"
        "sub  $64, %%rsp\n\t"           /* shadow space + room for args 5..8 */
        "movq $0, 32(%%rsp)\n\t"
        "movq $0, 40(%%rsp)\n\t"
        "movq $0, 48(%%rsp)\n\t"
        "movq $0, 56(%%rsp)\n\t"
        "mov  8(%%rbx), %%rcx\n\t"
        "mov  16(%%rbx), %%rdx\n\t"
        "xor  %%r8d, %%r8d\n\t"
        "xor  %%r9d, %%r9d\n\t"
        "mov  24(%%rbx), %%rdi\n\t"
        "mov  32(%%rbx), %%rsi\n\t"
        "call *(%%rbx)\n\t"
        "mov  %%r12, %%rsp\n\t"
        "mov  %%rax, 40(%%rbx)\n\t"
        "mov  %%rdi, 48(%%rbx)\n\t"
        "mov  %%rsi, 56(%%rbx)\n\t"
        :
        : "b"(p)
        : "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12",
          "memory", "cc", "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5",
          "xmm6", "xmm7", "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13",
          "xmm14", "xmm15");
}

static unsigned long long probe(void *fn, unsigned long long ms1, unsigned long long ms2,
                                unsigned long long sv1, unsigned long long sv2, int *kept)
{
    struct probe p = { fn, ms1, ms2, sv1, sv2, 0, 0, 0 };
    call_probe(&p);
    *kept = p.rdi_after == sv1 && p.rsi_after == sv2;
    return p.ret;
}

#define U(x) ((unsigned long long)(ULONG_PTR)(x))

static int part1_abi(void)
{
    static struct usb_bus bus_ms, bus_sv;
    static struct usb_device dev_ms, dev_sv;
    static const char *const names[] = {
        "usb_open", "usb_close", "usb_get_string_simple", "usb_bulk_read",
        "usb_interrupt_write", "usb_set_configuration", "usb_claim_interface",
        "usb_release_interface", "usb_clear_halt", "usb_reset", "usb_device",
        "usb_bulk_setup_async", "usb_submit_async", "usb_reap_async_nocancel",
        "usb_reap_async", "usb_cancel_async", "usb_free_async", "usb_set_debug",
        "usb_get_busses", "usb_strerror", "usb_find_busses", "usb_find_devices",
    };
    HMODULE m = GetModuleHandleA("libusb0.dll");
    const char *msg;
    unsigned long long h;
    int kept, ms_ok = 1, swept = 0, clobbered = 0;
    unsigned i;

    printf("\n[1] Calling convention (no hardware needed)\n");
    p_usb_init();

    /* usb_open: a different fake device in each convention's register */
    strcpy(bus_ms.dirname, "rcx-bus"); strcpy(dev_ms.filename, "rcx-dev"); dev_ms.bus = &bus_ms;
    strcpy(bus_sv.dirname, "rdi-bus"); strcpy(dev_sv.filename, "rdi-dev"); dev_sv.bus = &bus_sv;

    h = probe((void *)p_usb_open, U(&dev_ms), 0, U(&dev_sv), 0, &kept);
    msg = p_usb_strerror();
    if (msg && strstr(msg, "rcx-bus/rcx-dev"))
        PASS("usb_open reads its argument from rcx (Microsoft x64)");
    else if (msg && strstr(msg, "rdi-bus/rdi-dev")) {
        FAIL("usb_open reads its argument from rdi (System V): every Windows caller's arguments are lost");
        ms_ok = 0;
    } else {
        FAIL("usb_open: unexpected result \"%s\"", msg ? msg : "(null)");
        ms_ok = 0;
    }
    if (!kept) {
        FAIL("usb_open clobbers rdi/rsi, which a Windows caller expects preserved");
        ms_ok = 0;
    }

    /* second argument: rdx (Microsoft) vs rsi (System V). A broken library
       needs a handle in rdi, so give it the one it just returned. */
    probe((void *)p_usb_set_configuration, 0, 77, h, 55, &kept);
    msg = p_usb_strerror();
    if (msg && strstr(msg, "config 77"))
        PASS("usb_set_configuration reads its second argument from rdx");
    else if (msg && strstr(msg, "config 55")) {
        FAIL("usb_set_configuration reads its second argument from rsi (System V)");
        ms_ok = 0;
    } else {
        FAIL("usb_set_configuration: unexpected result \"%s\"", msg ? msg : "(null)");
        ms_ok = 0;
    }
    if (h)  /* a correct library returns NULL for an unopenable device */
        probe((void *)p_usb_close, h, 0, h, 0, &kept);

    if (!ms_ok) {
        INFO("skipping the per-function sweep: it would crash a System V build");
        return 0;
    }

    /* Every export: Microsoft argument registers zero, System V ones poisoned
       with non-canonical addresses. A Microsoft-convention function returns
       an error and preserves rdi/rsi; a System V one would crash or clobber. */
    for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        void *fn = (void *)GetProcAddress(m, names[i]);
        if (!fn)
            continue;
        probe(fn, 0, 0, 0x5151515151515151ULL, 0x7d7d7d7d7d7d7d7dULL, &kept);
        swept++;
        if (!kept) {
            FAIL("%s clobbers rdi/rsi", names[i]);
            clobbered++;
        }
    }
    if (!clobbered)
        PASS("all %d entry points take Microsoft x64 arguments and preserve rdi/rsi", swept);
    return 1;
}

/* ---- ANT messages ---------------------------------------------------------- */

static int ant_frame(unsigned char *out, unsigned char id, const unsigned char *data, int len)
{
    unsigned char cs = 0;
    int i;
    out[0] = 0xA4; out[1] = (unsigned char)len; out[2] = id;
    memcpy(out + 3, data, len);
    for (i = 0; i < 3 + len; i++) cs ^= out[i];
    out[3 + len] = cs;
    return 4 + len;
}

#define QMAX 256
static struct { unsigned char id, len, data[40]; } q[QMAX];
static LONG qhead, qtail;
static CRITICAL_SECTION qlock;
static HANDLE qevent;
static unsigned char stream[8192];
static int stream_len;

static void q_reset(void)
{
    EnterCriticalSection(&qlock);
    qhead = qtail = 0;
    LeaveCriticalSection(&qlock);
}

static void parse_stream(void)
{
    for (;;) {
        int start = 0, len, i;
        unsigned char cs = 0;
        while (start < stream_len && stream[start] != 0xA4) start++;
        if (start) { memmove(stream, stream + start, stream_len - start); stream_len -= start; }
        if (stream_len < 4) return;
        len = stream[1];
        if (len > 40) { memmove(stream, stream + 1, --stream_len); continue; }
        if (stream_len < 4 + len) return;
        for (i = 0; i < 3 + len; i++) cs ^= stream[i];
        if (cs == stream[3 + len]) {
            EnterCriticalSection(&qlock);
            if (qtail - qhead < QMAX) {
                int s = qtail % QMAX;
                q[s].id = stream[2];
                q[s].len = (unsigned char)len;
                memcpy(q[s].data, stream + 3, len);
                qtail++;
            }
            LeaveCriticalSection(&qlock);
            SetEvent(qevent);
        }
        memmove(stream, stream + 4 + len, stream_len - (4 + len));
        stream_len -= 4 + len;
    }
}

static int wait_for_msg(unsigned char id, unsigned char *data, DWORD ms)
{
    DWORD start = ms_now();
    for (;;) {
        int found = -1;
        EnterCriticalSection(&qlock);
        while (qhead < qtail) {
            int s = qhead % QMAX;
            qhead++;
            if (q[s].id == id) {
                if (data) memcpy(data, q[s].data, q[s].len);
                found = q[s].len;
                break;
            }
        }
        LeaveCriticalSection(&qlock);
        if (found >= 0) return found;
        if (ms_now() - start >= ms) return -1;
        WaitForSingleObject(qevent, 20);
    }
}

/* ---- ANT_DLL's device handle, reproduced ----------------------------------- */

static usb_dev_handle *device_handle;
static volatile LONG stop_receive;
static HANDLE receive_thread;
static LONG rx_reads, rx_timeouts, rx_aborts, rx_errors, rx_bytes;

/* USBDeviceHandleLibusb::ReceiveThread() */
static DWORD WINAPI receive_loop(LPVOID unused)
{
    static char aucData[4096];
    void *ctx = NULL;
    int submitted = 0, consec = 0, ret;
    (void)unused;

    ret = p_usb_bulk_setup_async(device_handle, &ctx, EP_IN);
    if (ret < 0) {
        InterlockedIncrement(&rx_errors);
        stop_receive = 1;
    }
    while (!stop_receive) {
        if (!submitted) {
            ret = p_usb_submit_async(ctx, aucData, sizeof(aucData));
            if (ret < 0) {
                InterlockedIncrement(&rx_errors);
                stop_receive = 1;
                break;
            }
            submitted = 1;
        }
        ret = p_usb_reap_async_nocancel(ctx, 1000);
        if (ret > 0) {
            InterlockedIncrement(&rx_reads);
            InterlockedExchangeAdd(&rx_bytes, ret);
            if (stream_len + ret <= (int)sizeof(stream)) {
                memcpy(stream + stream_len, aucData, ret);
                stream_len += ret;
                parse_stream();
            }
            submitted = 0;
            consec = 0;
        } else if (ret == -ETRANSFER_TIMEDOUT) {
            if (GetLastError() == 995) {        /* ANT_DLL: "stick lost power, start over" */
                InterlockedIncrement(&rx_aborts);
                stop_receive = 1;
            } else
                InterlockedIncrement(&rx_timeouts);
        } else if (ret < 0) {
            InterlockedIncrement(&rx_errors);
            if (++consec == 10)
                stop_receive = 1;
            else if (p_usb_cancel_async(ctx) == 0 && p_usb_free_async(&ctx) == 0 &&
                     p_usb_bulk_setup_async(device_handle, &ctx, EP_IN) == 0)
                submitted = 0;
            else
                stop_receive = 1;
        }
    }
    if (ctx) {
        p_usb_cancel_async(ctx);
        p_usb_free_async(&ctx);
    }
    return 0;
}

/* USBDeviceHandleLibusb::TryOpen() */
static int try_open(struct usb_device *dev)
{
    usb_dev_handle *h = p_usb_open(dev);
    if (!h)
        return 0;
    if (p_usb_set_configuration(h, 1) != 0 || p_usb_claim_interface(h, 0) != 0) {
        p_usb_close(h);
        return 0;
    }
    p_usb_release_interface(h, 0);
    p_usb_close(h);
    return 1;
}

/* USBDeviceHandleLibusb::POpen() */
static int ant_open(struct usb_device *dev)
{
    device_handle = p_usb_open(dev);
    if (!device_handle) { FAIL("usb_open: %s", p_usb_strerror()); return 0; }
    if (p_usb_set_configuration(device_handle, 1) != 0) {
        FAIL("usb_set_configuration(1): %s", p_usb_strerror());
        p_usb_close(device_handle);
        return 0;
    }
    if (p_usb_claim_interface(device_handle, 0) != 0) {
        FAIL("usb_claim_interface(0): %s", p_usb_strerror());
        p_usb_close(device_handle);
        return 0;
    }
    stop_receive = 0;
    stream_len = 0;
    q_reset();
    receive_thread = CreateThread(NULL, 0, receive_loop, NULL, 0, NULL);
    return receive_thread != NULL;
}

/* USBDeviceHandleLibusb::Write() */
static int ant_write(unsigned char id, const void *data, int len)
{
    unsigned char buf[48];
    int n = ant_frame(buf, id, (const unsigned char *)data, len);
    return p_usb_interrupt_write(device_handle, EP_OUT, (char *)buf, n, 3000);
}

/* USBDeviceHandleLibusb::PClose(); returns milliseconds taken */
static DWORD ant_close(void)
{
    DWORD t0 = ms_now();
    stop_receive = 1;
    if (WaitForSingleObject(receive_thread, 3000) != WAIT_OBJECT_0) {
        FAIL("receive thread did not stop within ANT_DLL's 3 s limit (it would kill it)");
        TerminateThread(receive_thread, 0);
    }
    CloseHandle(receive_thread);
    p_usb_release_interface(device_handle, 0);
    p_usb_close(device_handle);
    device_handle = NULL;
    return ms_now() - t0;
}

static void part2_ant(void)
{
    static const unsigned char zero = 0;
    struct usb_bus *bus;
    struct usb_device *dev, *ant = NULL;
    unsigned char data[40];
    char str[128];
    int ret, i, n, ok, devices = 0;
    LONG timeouts_before, reads_before;
    DWORD t0, dt, worst = 0, total = 0;

    printf("\n[2] ANT stick\n");
    InitializeCriticalSection(&qlock);
    qevent = CreateEventA(NULL, FALSE, FALSE, NULL);

    /* USBDeviceHandleLibusb::GetAllDevices(), with USBDeviceLibusb's
       constructor reading each device's strings */
    p_usb_init();
    if (p_usb_find_busses() < 0 || p_usb_find_devices() < 0) {
        FAIL("enumeration failed: %s", p_usb_strerror());
        return;
    }
    for (bus = p_usb_get_busses(); bus; bus = bus->next)
        for (dev = bus->devices; dev; dev = dev->next) {
            usb_dev_handle *h = p_usb_open(dev);
            char product[128] = "";
            devices++;
            if (h) {
                if (p_usb_get_string_simple(h, p_usb_device(h)->descriptor.iProduct, product, sizeof(product)) < 0)
                    product[0] = 0;
                p_usb_close(h);
            }
            /* GetAvailableDevices(): every device is trial-opened, then
               filtered by vendor */
            ret = try_open(dev);
            INFO("%s/%s  %04X:%04X  %-24s %s", bus->dirname, dev->filename,
                 dev->descriptor.idVendor, dev->descriptor.idProduct,
                 product[0] ? product : "(no name)", ret ? "openable" : "not openable");
            if (ret && !ant && (dev->descriptor.idVendor == 0x0FCF || dev->descriptor.idVendor == 0x1915))
                ant = dev;
        }

    if (!devices) {
        INFO("no USB devices visible to Windows programs.");
        INFO("If the ANT stick is plugged in, this user cannot write to it: check the udev rule.");
        return;
    }
    if (!ant) {
        INFO("no openable ANT stick among %d visible device(s)", devices);
        return;
    }
    PASS("ANT stick %04X:%04X found and trial-opened the way ANT_DLL does",
         ant->descriptor.idVendor, ant->descriptor.idProduct);
    stick_tested = 1;

    if (ant->config && ant->config->interface && ant->config->interface->altsetting) {
        struct usb_interface_descriptor *alt = ant->config->interface->altsetting;
        static const char *const types[] = { "control", "isochronous", "bulk", "interrupt" };
        for (i = 0; i < alt->bNumEndpoints; i++)
            INFO("endpoint 0x%02X  %-9s  max packet %d", alt->endpoint[i].bEndpointAddress,
                 types[alt->endpoint[i].bmAttributes & 3], alt->endpoint[i].wMaxPacketSize);
    }

    if (!ant_open(ant))
        return;
    PASS("opened, configured and claimed; receive thread running");

    if (p_usb_get_string_simple(device_handle, ant->descriptor.iSerialNumber, str, sizeof(str)) > 0)
        INFO("USB serial: %s", str);

    /* the open-time workaround ANT_DLL does for USB2/USB-m firmware */
    ant_write(0x4D, "\x00\x54", 2);
    ant_write(0x4D, "\x00\x54", 2);
    Sleep(50);

    q_reset();
    t0 = ms_now();
    ret = ant_write(0x4A, &zero, 1);                    /* reset */
    if (ret != 5)
        FAIL("usb_interrupt_write(reset) returned %d: %s", ret, p_usb_strerror());
    else if (wait_for_msg(0x6F, data, 3000) >= 0)
        PASS("reset -> startup message in %lu ms", ms_now() - t0);
    else
        FAIL("no startup message after reset");
    Sleep(500);

    if (ant_write(0x4D, "\x00\x54", 2) == 6 && (n = wait_for_msg(0x54, data, 2000)) >= 2)
        PASS("capabilities: %d channels, %d networks", data[0], data[1]);
    else
        FAIL("no capabilities response");

    if (ant_write(0x4D, "\x00\x61", 2) == 6 && wait_for_msg(0x61, data, 2000) >= 4)
        PASS("ANT serial number %lu", (unsigned long)(data[0] | data[1] << 8 | data[2] << 16 | (unsigned long)data[3] << 24));
    else
        FAIL("no serial number response");

    if (ant_write(0x4D, "\x00\x3E", 2) == 6 && (n = wait_for_msg(0x3E, data, 2000)) > 0) {
        data[n < 39 ? n : 39] = 0;
        PASS("firmware %s", (char *)data);
    } else
        FAIL("no version response");

    /* The pattern the old library could not survive: writes on this thread
       while the receive thread keeps an async read pending. */
    ok = 0;
    for (i = 0; i < 200; i++) {
        t0 = ms_now();
        if (ant_write(0x4D, "\x00\x54", 2) == 6 && wait_for_msg(0x54, data, 1000) >= 2) {
            dt = ms_now() - t0;
            ok++;
            total += dt;
            if (dt > worst) worst = dt;
        }
    }
    if (ok == 200)
        PASS("200/200 request/response round trips, average %lu ms, worst %lu ms", total / 200, worst);
    else
        FAIL("%d/200 round trips completed", ok);

    /* idle long enough for the receive thread's 1 s reaps to time out */
    timeouts_before = rx_timeouts;
    reads_before = rx_reads;
    Sleep(2500);
    if (rx_aborts)
        FAIL("a timeout reported ERROR_OPERATION_ABORTED: ANT_DLL would drop the stick");
    else if (rx_timeouts > timeouts_before)
        PASS("idle reads time out with -116 and a last error ANT_DLL treats as routine");
    else if (rx_reads > reads_before)
        INFO("the stick kept sending data, so reads never sat idle long enough to time out");
    else
        FAIL("idle reads never timed out (rx timeouts %ld)", rx_timeouts);

    dt = ant_close();
    if (dt < 1500)
        PASS("shut down the way ANT_DLL does in %lu ms", dt);
    else
        FAIL("shutdown took %lu ms", dt);
    INFO("receive thread: %ld reads, %ld bytes, %ld timeouts, %ld errors",
         rx_reads, rx_bytes, rx_timeouts, rx_errors);
    if (rx_errors)
        FAIL("the receive thread saw %ld errors", rx_errors);

    /* Zwift reopens the stick after pairing screens and errors */
    if (try_open(ant) && ant_open(ant)) {
        q_reset();
        if (ant_write(0x4D, "\x00\x54", 2) == 6 && wait_for_msg(0x54, data, 2000) >= 2)
            PASS("closed and reopened cleanly");
        else
            FAIL("no response after reopening");
        ant_close();
    } else
        FAIL("could not reopen the stick");
}

int main(void)
{
    HMODULE m;
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("ant-test: libusb0.dll check\n\n[0] Exports\n");
    m = LoadLibraryA("libusb0.dll");
    if (!m) { FAIL("could not load libusb0.dll (error %lu)", GetLastError()); return 1; }
    if (resolve(m) == 0)
        PASS("all 21 functions ANT_DLL imports are exported");

    if (part1_abi() && !failures)
        part2_ant();

    if (failures)
        printf("\nRESULT: FAILED\n");
    else if (stick_tested)
        printf("\nRESULT: ALL PASSED\n");
    else
        printf("\nRESULT: PASSED, but without a stick: only the library was tested\n");
    return failures ? 1 : 0;
}
