#include <stdbool.h>

// Flutter Rust Bridge can emit an empty header for reduced-dependency builds.
// These application entry points are exported directly by src/flutter.rs.
bool camellia_remote_core_main(void);
void handle_applicationShouldOpenUntitledFile(void);
