/*
 * Stand-ins for Zwift's programs, so that tests/rehearse.sh can run
 * zwift.sh without Zwift. One file, three programs:
 *
 *   -DLAUNCHER  ZwiftLauncher.exe: lives four seconds and exits, as
 *               launcher 1.2.0 does under Wine
 *   -DRFP       RunFromProcess-x64.exe PARENT CHILD: starts CHILD as a
 *               child of the running PARENT, as the real tool does
 *   -DAPP       ZwiftApp.exe: loads libusb0.dll by name and uses the ANT
 *               stick the way ANT_DLL does, with a read always pending,
 *               for ZWIFT_STUB_MS milliseconds; then writes what happened
 *               to ZWIFT_STUB_OUT
 *
 * Built with mingw; -DAPP needs libusb-wine's src/ on the include path.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#ifdef LAUNCHER
int main(void)
{
    Sleep(4000);
    return 0;
}
#endif

#ifdef RFP
#include <tlhelp32.h>

int main(int argc, char **argv)
{
    PROCESSENTRY32 entry = { sizeof(entry) };
    HANDLE snapshot, parent = NULL;
    STARTUPINFOEXA si;
    PROCESS_INFORMATION pi;
    SIZE_T size = 0;
    char command[MAX_PATH];

    if (argc != 3)
        return 2;
    snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (Process32First(snapshot, &entry))
        do
            if (!_stricmp(entry.szExeFile, argv[1])) {
                parent = OpenProcess(PROCESS_CREATE_PROCESS, FALSE, entry.th32ProcessID);
                break;
            }
        while (Process32Next(snapshot, &entry));
    CloseHandle(snapshot);
    if (!parent) {
        fprintf(stderr, "%s is not running\n", argv[1]);
        return 1;
    }

    memset(&si, 0, sizeof(si));
    si.StartupInfo.cb = sizeof(si);
    InitializeProcThreadAttributeList(NULL, 1, 0, &size);
    si.lpAttributeList = HeapAlloc(GetProcessHeap(), 0, size);
    InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &size);
    UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PARENT_PROCESS,
                              &parent, sizeof(parent), NULL, NULL);
    snprintf(command, sizeof(command), "%s", argv[2]);
    if (!CreateProcessA(NULL, command, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT,
                        NULL, NULL, &si.StartupInfo, &pi)) {
        fprintf(stderr, "CreateProcess failed: %lu\n", GetLastError());
        return 1;
    }
    return 0;
}
#endif

#ifdef APP
#include <stdint.h>
#undef interface                /* the Windows headers define it as struct */
typedef uint8_t u_int8_t;       /* the BSD names usb.h uses */
typedef uint16_t u_int16_t;
typedef uint32_t u_int32_t;
#include "usb.h"

#define LOOKUP(name) name##_t p_##name = (name##_t)(void (*)(void))GetProcAddress(m, #name)

typedef void (*usb_init_t)(void);
typedef int (*usb_find_busses_t)(void);
typedef int (*usb_find_devices_t)(void);
typedef struct usb_bus *(*usb_get_busses_t)(void);
typedef usb_dev_handle *(*usb_open_t)(struct usb_device *);
typedef int (*usb_set_configuration_t)(usb_dev_handle *, int);
typedef int (*usb_claim_interface_t)(usb_dev_handle *, int);
typedef int (*usb_bulk_setup_async_t)(usb_dev_handle *, void **, unsigned char);
typedef int (*usb_submit_async_t)(void *, char *, int);
typedef int (*usb_reap_async_nocancel_t)(void *, int);
typedef int (*usb_cancel_async_t)(void *);
typedef int (*usb_free_async_t)(void **);
typedef int (*usb_interrupt_write_t)(usb_dev_handle *, int, char *, int, int);
typedef int (*usb_close_t)(usb_dev_handle *);

int main(void)
{
    static char data[4096];
    static char caps_request[] = { (char)0xa4, 0x02, 0x4d, 0x00, 0x54, (char)0xbf };
    char out[MAX_PATH] = "", path[MAX_PATH] = "", ms_text[32] = "6000";
    struct usb_bus *bus;
    struct usb_device *dev, *stick = NULL;
    usb_dev_handle *h;
    void *ctx = NULL;
    DWORD start, ms;
    int reads = 0, timeouts = 0, aborts = 0, ret;
    FILE *report = stdout;
    HMODULE m;

    if (GetEnvironmentVariableA("ZWIFT_STUB_OUT", out, sizeof(out)) && !(report = fopen(out, "w")))
        report = stdout;
    GetEnvironmentVariableA("ZWIFT_STUB_MS", ms_text, sizeof(ms_text));
    ms = (DWORD)atoi(ms_text);

    if (!(m = LoadLibraryA("libusb0.dll"))) {
        fprintf(report, "libusb0.dll: not loaded (error %lu)\n", GetLastError());
        fclose(report);
        Sleep(ms);
        return 1;
    }
    GetModuleFileNameA(m, path, sizeof(path));
    fprintf(report, "libusb0.dll: loaded as %s\n", path);
    {
        LOOKUP(usb_init); LOOKUP(usb_find_busses); LOOKUP(usb_find_devices);
        LOOKUP(usb_get_busses); LOOKUP(usb_open); LOOKUP(usb_set_configuration);
        LOOKUP(usb_claim_interface); LOOKUP(usb_bulk_setup_async); LOOKUP(usb_submit_async);
        LOOKUP(usb_reap_async_nocancel); LOOKUP(usb_cancel_async); LOOKUP(usb_free_async);
        LOOKUP(usb_interrupt_write); LOOKUP(usb_close);

        p_usb_init();
        p_usb_find_busses();
        p_usb_find_devices();
        for (bus = p_usb_get_busses(); bus; bus = bus->next)
            for (dev = bus->devices; dev; dev = dev->next)
                if (dev->descriptor.idVendor == 0x0fcf)
                    stick = dev;
        if (!stick) {
            fprintf(report, "ANT stick: not found\n");
            fclose(report);
            Sleep(ms);
            return 1;
        }
        h = p_usb_open(stick);
        if (!h || p_usb_set_configuration(h, 1) || p_usb_claim_interface(h, 0)) {
            fprintf(report, "ANT stick: could not open it\n");
            fclose(report);
            Sleep(ms);
            return 1;
        }
        fprintf(report, "ANT stick: opened %04X:%04X\n",
                stick->descriptor.idVendor, stick->descriptor.idProduct);
        fflush(report);

        /* ANT_DLL's receive loop, with a request every 200 ms */
        p_usb_bulk_setup_async(h, &ctx, 0x81);
        p_usb_submit_async(ctx, data, sizeof(data));
        start = GetTickCount();
        while (GetTickCount() - start < ms && !aborts) {
            p_usb_interrupt_write(h, 0x01, caps_request, sizeof(caps_request), 3000);
            ret = p_usb_reap_async_nocancel(ctx, 1000);
            if (ret > 0) {
                reads++;
                p_usb_submit_async(ctx, data, sizeof(data));
            } else if (ret == -116) {
                if (GetLastError() == ERROR_OPERATION_ABORTED)
                    aborts++;
                else
                    timeouts++;
            }
            Sleep(200);
        }
        p_usb_cancel_async(ctx);
        p_usb_free_async(&ctx);
        p_usb_close(h);
    }
    fprintf(report, "receive loop: %d reads, %d timeouts, %d aborts\n", reads, timeouts, aborts);
    fclose(report);
    return 0;
}
#endif
