#import "server.h"
#import "kernel/krw.h"
#import "kernel/offsets.h"
#import <kern_memorystatus.h>
#import <libproc.h>

#ifdef __cplusplus
extern "C" {
#endif

xpc_object_t launchd_xpc_send_message(xpc_object_t xdict);
uid_t audit_token_to_euid(audit_token_t);
uid_t audit_token_to_pid(audit_token_t);

/*#undef JBLogDebug
void JBLogDebug(const char *format, ...)
{
        va_list va;
        va_start(va, format);

        FILE *launchdLog = fopen("/var/mobile/jailbreakd-xpc.log", "a");
        vfprintf(launchdLog, format, va);
        fprintf(launchdLog, "\n");
        fclose(launchdLog);

        va_end(va);
}*/

kern_return_t bootstrap_check_in(mach_port_t bootstrap_port,
                                 const char *service, mach_port_t *server_port);
SInt32 CFUserNotificationDisplayAlert(
    CFTimeInterval timeout, CFOptionFlags flags, CFURLRef iconURL,
    CFURLRef soundURL, CFURLRef localizationURL, CFStringRef alertHeader,
    CFStringRef alertMessage, CFStringRef defaultButtonTitle,
    CFStringRef alternateButtonTitle, CFStringRef otherButtonTitle,
    CFOptionFlags *responseFlags) API_AVAILABLE(ios(3.0));

#ifdef __cplusplus
}
#endif

void setJetsamEnabled(bool enabled) {
  pid_t me = getpid();
  int priorityToSet = -1;
  if (enabled) {
    priorityToSet = 10;
  }
  int rc = memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK, me,
                                priorityToSet, NULL, 0);
  if (rc < 0) {
    perror("memorystatus_control");
    exit(rc);
  }
}

bool boolValueForEntitlement(audit_token_t *token, const char *entitlement) {
  xpc_object_t entitlementValue =
      xpc_copy_entitlement_for_token(entitlement, token);
  if (entitlementValue) {
    if (xpc_get_type(entitlementValue) == XPC_TYPE_BOOL) {
      return xpc_bool_get_value(entitlementValue);
    }
  }
  return false;
}

NSString *proc_get_path(pid_t pid) {
  char pathbuf[4 * MAXPATHLEN];
  int ret = proc_pidpath(pid, pathbuf, sizeof(pathbuf));
  if (ret <= 0)
    return nil;
  return [[[NSString stringWithUTF8String:pathbuf]
      stringByResolvingSymlinksInPath] stringByStandardizingPath];
}

void jailbreakd_received_message(mach_port_t machPort, bool systemwide) {
  @autoreleasepool {
    xpc_object_t message = nil;
    int err = xpc_pipe_receive(machPort, &message);
    if (err != 0) {
      NSLog(@"[jailbreakd] xpc_pipe_receive error %d", err);
      return;
    }

    xpc_object_t reply = xpc_dictionary_create_reply(message);
    xpc_type_t messageType = xpc_get_type(message);
    int msgId = -1;
    if (messageType == XPC_TYPE_DICTIONARY) {
      audit_token_t auditToken = {};
      xpc_dictionary_get_audit_token(message, &auditToken);
      uid_t clientUid = audit_token_to_euid(auditToken);
      pid_t clientPid = audit_token_to_pid(auditToken);

      msgId = xpc_dictionary_get_uint64(message, "id");

      char *description = xpc_copy_description(message);
      NSLog(@"[jailbreakd] received %s message %d with dictionary: %s (from "
            @"binary: %s)",
            systemwide ? "systemwide" : "", msgId, description,
            proc_get_path(clientPid).UTF8String);
      free(description);
    }

    // handle
    if (msgId) {
      // check if kernel r/w received
      if (msgId == JBD_MSG_KRW_READY) {
        if (get_kbase() != 0)
          xpc_dictionary_set_uint64(reply, "krw_ready", 1);
        else
          xpc_dictionary_set_uint64(reply, "krw_ready", 0);
      }

      // grab kernel info
      if (msgId == JBD_MSG_KERNINFO) {
        xpc_dictionary_set_uint64(reply, "kbase", get_kbase());
        xpc_dictionary_set_uint64(reply, "kslide", get_kslide());
        xpc_dictionary_set_uint64(reply, "allproc", get_allproc());
        xpc_dictionary_set_uint64(reply, "kernproc", get_kernproc());
      }

      // kread32
      if (msgId == JBD_MSG_KREAD32) {
        uint64_t kaddr = xpc_dictionary_get_uint64(message, "kaddr");
        xpc_dictionary_set_uint64(reply, "val", kread32(kaddr));
      }

      // kread64
      if (msgId == JBD_MSG_KREAD64) {
        uint64_t kaddr = xpc_dictionary_get_uint64(message, "kaddr");
        xpc_dictionary_set_uint64(reply, "val", kread64(kaddr));
      }

      //  kwrite32
      if (msgId == JBD_MSG_KWRITE32) {
        uint64_t kaddr = xpc_dictionary_get_uint64(message, "kaddr");
        uint32_t val = xpc_dictionary_get_uint64(message, "val");
        kwrite32(kaddr, val);
        xpc_dictionary_set_uint64(reply, "ret", kread32(kaddr) != val);
      }

      //  kwrite64
      if (msgId == JBD_MSG_KWRITE64) {
        uint64_t kaddr = xpc_dictionary_get_uint64(message, "kaddr");
        uint64_t val = xpc_dictionary_get_uint64(message, "val");
        kwrite64(kaddr, val);
        xpc_dictionary_set_uint64(reply, "ret", kread64(kaddr) != val);
      }

      //  kalloc
      if (msgId == JBD_MSG_KALLOC) {
        uint64_t ksize = xpc_dictionary_get_uint64(message, "ksize");
        init_kcall();
        uint64_t allocated_kmem = kalloc(ksize);
        xpc_dictionary_set_uint64(reply, "val", allocated_kmem);
        term_kcall();
      }

      //  kfree
      if (msgId == JBD_MSG_KFREE) {
        uint64_t kaddr = xpc_dictionary_get_uint64(message, "kaddr");
        uint64_t ksize = xpc_dictionary_get_uint64(message, "ksize");
        init_kcall();
        kfree(kaddr, ksize);
        xpc_dictionary_set_uint64(reply, "ret", 0);
        term_kcall();
      }
    }

    if (reply) {
      char *description = xpc_copy_description(reply);
      NSLog(@"[jailbreakd] responding to %s message %d with %s",
            systemwide ? "systemwide" : "", msgId, description);
      free(description);
      err = xpc_pipe_routine_reply(reply);
      if (err != 0) {
        NSLog(@"[jailbreakd] Error %d sending response", err);
      }
    }
  }
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    NSLog(@"[jailbreakd] Hello from the other side!");
    _offsets_init();

    get_kernel_rw();

    setJetsamEnabled(true);

    mach_port_t machPort = 0;
    kern_return_t kr =
        bootstrap_check_in(bootstrap_port, "kr.h4ck.jailbreakd", &machPort);
    if (kr != KERN_SUCCESS) {
      NSLog(
          @"[jailbreakd] Failed kr.h4ck.jailbreakd bootstrap check in: %d (%s)",
          kr, mach_error_string(kr));
      return 1;
    }

    mach_port_t machPortSystemWide = 0;
    kr = bootstrap_check_in(bootstrap_port, "kr.h4ck.jailbreakd.systemwide",
                            &machPortSystemWide);
    if (kr != KERN_SUCCESS) {
      NSLog(@"[jailbreakd] Failed kr.h4ck.jailbreakd.systemwide bootstrap "
            @"check in: %d (%s)",
            kr, mach_error_string(kr));
      return 1;
    }

    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MACH_RECV, (uintptr_t)machPort, 0,
        dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
      mach_port_t lMachPort = (mach_port_t)dispatch_source_get_handle(source);
      jailbreakd_received_message(lMachPort, false);
    });
    dispatch_resume(source);

    dispatch_source_t sourceSystemWide = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MACH_RECV, (uintptr_t)machPortSystemWide, 0,
        dispatch_get_main_queue());
    dispatch_source_set_event_handler(sourceSystemWide, ^{
      mach_port_t lMachPort =
          (mach_port_t)dispatch_source_get_handle(sourceSystemWide);
      jailbreakd_received_message(lMachPort, true);
    });
    dispatch_resume(sourceSystemWide);

    dispatch_main();
    return 0;
  }
}