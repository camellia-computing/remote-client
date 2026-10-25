use std::{
    hint::spin_loop,
    sync::atomic::{AtomicI32, AtomicU32, Ordering},
};

/// A single-producer, single-consumer handoff for one shared-memory slot.
///
/// The producer may modify the slot only while `can_publish()` is true. It
/// publishes the completed payload with `publish()`. The consumer holds the
/// returned guard while copying the payload; dropping the guard acknowledges
/// the generation and lets the producer reuse the slot.
#[repr(C, align(8))]
pub(crate) struct SharedSlotCounter {
    published: AtomicU32,
    consumed: AtomicU32,
}

impl SharedSlotCounter {
    pub(crate) fn can_publish(&self) -> bool {
        self.published.load(Ordering::Relaxed) == self.consumed.load(Ordering::Acquire)
    }

    pub(crate) fn publish(&self) -> bool {
        let published = self.published.load(Ordering::Relaxed);
        if self.consumed.load(Ordering::Acquire) != published {
            return false;
        }
        self.published
            .store(published.wrapping_add(1), Ordering::Release);
        true
    }

    pub(crate) fn try_acquire(&self) -> Option<SharedSlotReadGuard<'_>> {
        let published = self.published.load(Ordering::Acquire);
        if self.consumed.load(Ordering::Relaxed) == published {
            return None;
        }
        Some(SharedSlotReadGuard {
            counter: self,
            generation: published,
        })
    }

    #[cfg(test)]
    fn with_generation(published: u32, consumed: u32) -> Self {
        Self {
            published: AtomicU32::new(published),
            consumed: AtomicU32::new(consumed),
        }
    }
}

pub(crate) struct SharedSlotReadGuard<'a> {
    counter: &'a SharedSlotCounter,
    generation: u32,
}

impl Drop for SharedSlotReadGuard<'_> {
    fn drop(&mut self) {
        self.counter
            .consumed
            .store(self.generation, Ordering::Release);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CaptureParameters {
    pub(crate) capture_epoch: u32,
    pub(crate) current_display: u32,
    pub(crate) timeout_ms: i32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CaptureParametersSnapshot {
    pub(crate) generation: u32,
    pub(crate) value: CaptureParameters,
}

/// Atomic seqlock representation of the main-process capture parameters.
///
/// There is exactly one writer (the main process). Every payload field is
/// atomic so a reader retry never performs a data-racing ordinary load.
#[repr(C, align(8))]
pub(crate) struct SharedCaptureParameters {
    sequence: AtomicU32,
    capture_epoch: AtomicU32,
    current_display: AtomicU32,
    timeout_ms: AtomicI32,
}

impl SharedCaptureParameters {
    pub(crate) fn write(&self, value: CaptureParameters) {
        let sequence = self.sequence.load(Ordering::SeqCst);
        debug_assert_eq!(
            sequence & 1,
            0,
            "capture parameter writer must be single-owner"
        );
        let (writing, complete) = if sequence >= u32::MAX - 1 {
            (1, 2)
        } else {
            (sequence + 1, sequence + 2)
        };
        self.sequence.store(writing, Ordering::SeqCst);
        self.capture_epoch
            .store(value.capture_epoch, Ordering::SeqCst);
        self.current_display
            .store(value.current_display, Ordering::SeqCst);
        self.timeout_ms.store(value.timeout_ms, Ordering::SeqCst);
        self.sequence.store(complete, Ordering::SeqCst);
    }

    pub(crate) fn read(&self) -> Option<CaptureParametersSnapshot> {
        for _ in 0..16 {
            let before = self.sequence.load(Ordering::SeqCst);
            if before == 0 || before & 1 != 0 {
                spin_loop();
                continue;
            }
            let value = CaptureParameters {
                capture_epoch: self.capture_epoch.load(Ordering::SeqCst),
                current_display: self.current_display.load(Ordering::SeqCst),
                timeout_ms: self.timeout_ms.load(Ordering::SeqCst),
            };
            let after = self.sequence.load(Ordering::SeqCst);
            if before == after {
                return Some(CaptureParametersSnapshot {
                    generation: after,
                    value,
                });
            }
            spin_loop();
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn slot_is_not_reused_until_read_guard_is_dropped() {
        let counter = SharedSlotCounter::with_generation(0, 0);
        assert!(counter.can_publish());
        assert!(counter.publish());
        assert!(!counter.can_publish());
        assert!(!counter.publish());

        let guard = counter.try_acquire().expect("published slot");
        assert!(!counter.can_publish());
        drop(guard);
        assert!(counter.can_publish());
    }

    #[test]
    fn slot_generation_wrap_does_not_look_consumed() {
        let counter = SharedSlotCounter::with_generation(u32::MAX, u32::MAX);
        assert!(counter.publish());
        assert!(!counter.can_publish());
        let guard = counter.try_acquire().expect("wrapped generation");
        drop(guard);
        assert!(counter.can_publish());
    }

    #[test]
    fn capture_parameters_require_a_completed_generation() {
        let params = SharedCaptureParameters {
            sequence: AtomicU32::new(0),
            capture_epoch: AtomicU32::new(0),
            current_display: AtomicU32::new(0),
            timeout_ms: AtomicI32::new(0),
        };
        assert_eq!(params.read(), None);
        params.write(CaptureParameters {
            capture_epoch: 9,
            current_display: 7,
            timeout_ms: 33,
        });
        assert_eq!(
            params.read(),
            Some(CaptureParametersSnapshot {
                generation: 2,
                value: CaptureParameters {
                    capture_epoch: 9,
                    current_display: 7,
                    timeout_ms: 33,
                },
            })
        );
    }

    #[test]
    fn capture_parameter_generation_wrap_skips_uninitialized_zero() {
        let params = SharedCaptureParameters {
            sequence: AtomicU32::new(u32::MAX - 1),
            capture_epoch: AtomicU32::new(1),
            current_display: AtomicU32::new(1),
            timeout_ms: AtomicI32::new(1),
        };
        params.write(CaptureParameters {
            capture_epoch: 2,
            current_display: 3,
            timeout_ms: 4,
        });
        assert_eq!(params.read().unwrap().generation, 2);
    }

    #[test]
    fn capture_parameter_reader_never_observes_a_mixed_tuple() {
        let params = Arc::new(SharedCaptureParameters {
            sequence: AtomicU32::new(0),
            capture_epoch: AtomicU32::new(0),
            current_display: AtomicU32::new(0),
            timeout_ms: AtomicI32::new(0),
        });
        params.write(CaptureParameters {
            capture_epoch: 1,
            current_display: 1,
            timeout_ms: 1,
        });

        let writer = params.clone();
        let handle = std::thread::spawn(move || {
            for i in 1..=20_000_u32 {
                writer.write(CaptureParameters {
                    capture_epoch: i,
                    current_display: i,
                    timeout_ms: i as i32,
                });
            }
        });
        for _ in 0..20_000 {
            if let Some(snapshot) = params.read() {
                assert_eq!(
                    snapshot.value.current_display as i32,
                    snapshot.value.timeout_ms
                );
                assert_eq!(snapshot.value.capture_epoch, snapshot.value.current_display);
            }
        }
        handle.join().unwrap();
    }
}
