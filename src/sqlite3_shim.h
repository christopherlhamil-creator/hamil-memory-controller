/* Thin shim so build.zig's TranslateC step has a stable local path to
 * translate, rather than hardcoding a host-specific absolute path to the
 * system sqlite3.h. Resolves via the default system include search path. */
#include <sqlite3.h>
