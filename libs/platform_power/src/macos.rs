use anyhow::{bail, Result as ResultType};
use objc2_core_foundation::CFString;
use objc2_io_kit::{
    kIOPMAssertionLevelOn, kIOReturnSuccess, IOPMAssertionCreateWithName, IOPMAssertionID,
    IOPMAssertionRelease,
};

pub struct PowerInhibitor(Vec<IOPMAssertionID>);

impl PowerInhibitor {
    pub fn new(display: bool, idle: bool, sleep: bool) -> ResultType<Self> {
        let mut guard = Self(Vec::new());
        for (requested, name) in [
            (display, "PreventUserIdleDisplaySleep"),
            (idle, "PreventUserIdleSystemSleep"),
            (sleep, "PreventSystemSleep"),
        ] {
            if !requested {
                continue;
            }
            let assertion_type = CFString::from_str(name);
            let reason = CFString::from_static_str("Active Camellia remote session");
            let mut id = 0;
            let result = unsafe {
                IOPMAssertionCreateWithName(
                    Some(&assertion_type),
                    kIOPMAssertionLevelOn,
                    Some(&reason),
                    &mut id,
                )
            };
            if result != kIOReturnSuccess {
                bail!("Power protection was rejected ({result:#010x})");
            }
            guard.0.push(id);
        }
        Ok(guard)
    }
}

impl Drop for PowerInhibitor {
    fn drop(&mut self) {
        for id in self.0.drain(..) {
            let result = IOPMAssertionRelease(id);
            if result != kIOReturnSuccess {
                log::warn!("Unable to release session power protection ({result:#010x})");
            }
        }
    }
}
