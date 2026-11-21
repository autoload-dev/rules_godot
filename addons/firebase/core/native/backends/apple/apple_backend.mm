// iOS: FirebaseCore.framework of //ios, configured from the
// GoogleService-Info.plist the application bundles.
#include "firebase/core/native/backend.h"
#import <FirebaseCore/FirebaseCore.h>

namespace firebase_core {
bool backend_is_supported() { return true; }

bool backend_initialize() {
  if ([FIRApp defaultApp] != nil) return true;
  // +configure raises an exception without the plist; report it as unconfigured instead.
  if ([[NSBundle mainBundle] pathForResource:@"GoogleService-Info" ofType:@"plist"] == nil) {
    return false;
  }
  [FIRApp configure];
  return [FIRApp defaultApp] != nil;
}

bool backend_is_initialized() { return [FIRApp defaultApp] != nil; }
} // namespace firebase_core
