/* Overlay glue (id-011 follow-up), not an Apple header. Lets Apple's
 * libdispatch-1542.100.32 private headers parse against the public macOS SDK:
 * 1. the SDK's <dispatch/base.h> defines DISPATCH_ENUM_SPI_AVAILABLE(...) as
 *    API_UNAVAILABLE(__VA_ARGS__), which cannot take versioned arguments such
 *    as macos(26.4): neutralize that enum attribute;
 * 2. the public SDK has no availability helpers for the internal bridgeos
 *    platform: map them the way the SDK maps the public platforms.
 * Then include Apple's private.h. */
#include <dispatch/dispatch.h>
#undef DISPATCH_ENUM_SPI_AVAILABLE
#define DISPATCH_ENUM_SPI_AVAILABLE(...)
#ifndef __API_AVAILABLE_PLATFORM_bridgeos
#define __API_AVAILABLE_PLATFORM_bridgeos(x) bridgeos,introduced=x
#define __API_DEPRECATED_PLATFORM_bridgeos(x,y) bridgeos,introduced=x,deprecated=y
#define __API_UNAVAILABLE_PLATFORM_bridgeos bridgeos,unavailable
#endif
#include "/Volumes/MM4-1T/Local/swift-rx/swift-sdk-op-233/results-id-011-followup/private-headers/src/libdispatch/private/private.h"
