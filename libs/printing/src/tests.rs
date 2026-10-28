use super::*;
use std::sync::{Arc, Barrier};

#[test]
fn default_printer_buffer_is_bounded_and_removes_exactly_one_terminator() {
    assert_eq!(decode_default_printer(&[b'A' as u16, 0], 2).unwrap(), "A");
    assert_eq!(
        decode_default_printer(&[0xD83D, 0xDDA8, 0], 3).unwrap(),
        "🖨"
    );
    for (name, reported) in [
        (vec![], 0),
        (vec![0], 1),
        (vec![b'A' as u16, 0], 3),
        (vec![b'A' as u16, b'B' as u16], 2),
        (vec![b'A' as u16, 0, 0], 3),
        (vec![0xD800, 0], 2),
        (
            vec![b'A' as u16; MAX_PRINTER_NAME_UNITS + 2],
            (MAX_PRINTER_NAME_UNITS + 2) as u32,
        ),
    ] {
        assert_eq!(
            decode_default_printer(&name, reported).unwrap_err().stage,
            PrintStage::ResolveDefaultPrinter
        );
    }
}

#[test]
fn unspecified_advisory_dimensions_are_valid_but_nan_and_zero_are_not() {
    for value in [-1.0, 1.0, 816.0, 1056.0] {
        assert!(valid_advisory_dimension(value));
    }
    for value in [
        -2.0,
        -0.5,
        0.0,
        0.5,
        f32::NAN,
        f32::INFINITY,
        f32::NEG_INFINITY,
    ] {
        assert!(!valid_advisory_dimension(value));
    }
}

#[derive(Default)]
struct FakeBackend {
    fail: Option<PrintStage>,
    cancel_error: Option<i32>,
    calls: Vec<&'static str>,
    panic_on_write: bool,
    manifest: Option<PrintSubmission>,
}

impl FakeBackend {
    fn step(&mut self, stage: PrintStage) -> Result<(), PrintError> {
        self.calls.push(stage.code());
        if self.fail == Some(stage) {
            Err(PrintError::new(stage))
        } else {
            Ok(())
        }
    }
}

impl PackageBackend for FakeBackend {
    fn prepare(&mut self, _: &[u8]) -> Result<PrintSubmission, PrintError> {
        self.step(PrintStage::ReadPackage)?;
        Ok(self.manifest.unwrap_or(PrintSubmission {
            documents: 1,
            pages: 2,
        }))
    }
    fn create_target(&mut self, _: &str) -> Result<(), PrintError> {
        self.step(PrintStage::CreateTarget)
    }
    fn select_target(&mut self) -> Result<(), PrintError> {
        self.step(PrintStage::SelectTarget)
    }
    fn open_writer(&mut self) -> Result<(), PrintError> {
        self.step(PrintStage::OpenWriter)
    }
    fn write_document(&mut self) -> Result<(), PrintError> {
        assert!(!self.panic_on_write, "injected backend unwind");
        self.step(PrintStage::WriteDocument)
    }
    fn close_writer(&mut self) -> Result<(), PrintError> {
        self.step(PrintStage::CloseWriter)
    }
    fn cancel(&mut self) -> Result<(), i32> {
        self.calls.push("cancel");
        self.cancel_error.map_or(Ok(()), Err)
    }
}

#[test]
fn invalid_input_has_no_backend_side_effect() {
    let long_name = "印".repeat(MAX_PRINTER_NAME_UNITS + 1);
    for (name, bytes) in [
        ("", b"xps".as_slice()),
        ("queue\0other", b"xps".as_slice()),
        (long_name.as_str(), b"xps".as_slice()),
        ("queue", b"".as_slice()),
    ] {
        let mut backend = FakeBackend::default();
        let error = submit_with_backend(name, bytes, &mut backend).unwrap_err();
        assert_eq!(error.stage, PrintStage::ValidateRequest);
        assert!(backend.calls.is_empty());
    }
    let oversized = vec![0; MAX_DOCUMENT_BYTES + 1];
    assert!(validate_request("queue", &oversized).is_err());
    assert!(validate_request("queue", &oversized[..MAX_DOCUMENT_BYTES]).is_ok());
    assert!(validate_request(&"🖨".repeat(MAX_PRINTER_NAME_UNITS / 2), b"xps").is_ok());
    assert!(validate_request(&"🖨".repeat(MAX_PRINTER_NAME_UNITS / 2 + 1), b"xps").is_err());
}

#[test]
fn invalid_manifest_never_creates_a_system_print_job() {
    for manifest in [
        PrintSubmission {
            documents: 0,
            pages: 1,
        },
        PrintSubmission {
            documents: MAX_DOCUMENTS + 1,
            pages: 1,
        },
        PrintSubmission {
            documents: 1,
            pages: 0,
        },
        PrintSubmission {
            documents: 1,
            pages: MAX_PAGES + 1,
        },
    ] {
        let mut backend = FakeBackend {
            manifest: Some(manifest),
            ..Default::default()
        };
        assert_eq!(
            submit_with_backend("queue", b"xps", &mut backend)
                .unwrap_err()
                .stage,
            PrintStage::ReadPackage
        );
        assert_eq!(backend.calls, ["read_package"]);
    }
}

#[test]
fn every_failure_stops_and_cancels_once_without_replacing_primary_error() {
    let stages = [
        PrintStage::ReadPackage,
        PrintStage::CreateTarget,
        PrintStage::SelectTarget,
        PrintStage::OpenWriter,
        PrintStage::WriteDocument,
        PrintStage::CloseWriter,
    ];
    for (index, stage) in stages.into_iter().enumerate() {
        for cancel_error in [None, Some(-1234)] {
            let mut backend = FakeBackend {
                fail: Some(stage),
                cancel_error,
                ..Default::default()
            };
            let error = submit_with_backend("queue", b"xps", &mut backend).unwrap_err();
            assert_eq!(error.stage, stage);
            let expected: Vec<_> = stages[..=index].iter().map(|s| s.code()).collect();
            if stage == PrintStage::ReadPackage {
                assert_eq!(backend.calls, expected);
                assert_eq!(error.cancel_code, None);
            } else {
                assert_eq!(backend.calls[..=index], expected);
                assert_eq!(backend.calls[index + 1..], ["cancel"]);
                assert_eq!(error.cancel_code, cancel_error);
            }
        }
    }
}

#[test]
fn accepted_is_not_reported_until_writer_closes_and_never_retries() {
    let mut backend = FakeBackend::default();
    assert_eq!(
        submit_with_backend("queue", b"xps", &mut backend).unwrap(),
        PrintSubmission {
            documents: 1,
            pages: 2
        }
    );
    assert_eq!(
        backend.calls,
        [
            "read_package",
            "create_target",
            "select_target",
            "open_writer",
            "write_document",
            "close_writer"
        ]
    );
}

#[test]
fn unwinding_cancels_an_uncommitted_job_once() {
    let mut backend = FakeBackend {
        panic_on_write: true,
        ..Default::default()
    };
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        submit_with_backend("queue", b"xps", &mut backend)
    }));
    assert!(result.is_err());
    assert_eq!(
        backend
            .calls
            .iter()
            .filter(|step| **step == "cancel")
            .count(),
        1
    );
    assert!(!backend.calls.contains(&"close_writer"));
}

#[test]
fn concurrent_first_use_and_repeated_submissions_share_no_loader_state() {
    let start = Arc::new(Barrier::new(32));
    let workers: Vec<_> = (0..32)
        .map(|_| {
            let start = start.clone();
            std::thread::spawn(move || {
                start.wait();
                for _ in 0..100 {
                    let mut backend = FakeBackend::default();
                    assert!(submit_with_backend("queue", b"xps", &mut backend).is_ok());
                    assert_eq!(backend.calls.len(), 6);
                }
            })
        })
        .collect();
    for worker in workers {
        worker.join().unwrap();
    }
}

#[test]
fn diagnostics_do_not_include_printer_name_or_document_content() {
    let mut backend = FakeBackend {
        fail: Some(PrintStage::WriteDocument),
        ..Default::default()
    };
    let error =
        submit_with_backend("private-printer-name", b"secret-document", &mut backend).unwrap_err();
    assert_eq!(error.to_string(), "print stage=write_document");
    assert!(!format!("{error:?}").contains("private"));
    assert!(!format!("{error:?}").contains("secret"));
}
