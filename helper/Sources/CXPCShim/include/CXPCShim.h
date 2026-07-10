// CXPCShim — vends the XPC audit-token SPI that the public Swift `XPC` module
// does not surface. `xpc_connection_copy_audit_token` is declared in Apple's
// private <xpc/private.h> (not in the public module map), but it is a stable,
// widely-used symbol present in libSystem. We declare it here and wrap it so
// the Swift daemon can obtain the peer's audit_token for SecCode validation
// (SRAA §3 caller authentication) — WITHOUT importing a private header.
//
// This is the macOS-correct peer-identity primitive (NOT SO_PEERCRED, which is
// Linux-only — SRAA §13.1 M-03).
#ifndef CXPCSHIM_H
#define CXPCSHIM_H

#include <xpc/xpc.h>
#include <bsm/libbsm.h>   // audit_token_t

// Forward declaration of the SPI (present in libSystem; declared in the
// private <xpc/private.h> upstream). Declaring it extern here lets us link it
// without pulling in the private header.
extern void xpc_connection_get_audit_token(xpc_connection_t connection,
                                           audit_token_t *token);

// Thin wrapper so the Swift side calls a plainly-named function.
static inline void cxpc_connection_copy_audit_token(xpc_connection_t connection,
                                                    audit_token_t *token) {
    xpc_connection_get_audit_token(connection, token);
}

#endif /* CXPCSHIM_H */
