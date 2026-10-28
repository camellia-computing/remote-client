//! Owned print submission, without a dynamically loaded, process-global adapter.
//!
//! A successful submission means the spooler accepted the document package, not
//! that paper was produced. Never retry an ambiguous submission automatically.

use std::{error::Error, fmt};

pub const MAX_DOCUMENT_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_DOCUMENTS: u32 = 128;
pub const MAX_PAGES: u32 = 4096;
const MAX_PRINTER_NAME_UNITS: usize = 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PrintStage {
    ValidateRequest,
    ResolveDefaultPrinter,
    InitializeCom,
    ReadPackage,
    CreateTarget,
    SelectTarget,
    OpenWriter,
    WriteDocument,
    CloseWriter,
}

impl PrintStage {
    pub fn code(self) -> &'static str {
        match self {
            Self::ValidateRequest => "validate_request",
            Self::ResolveDefaultPrinter => "resolve_default_printer",
            Self::InitializeCom => "initialize_com",
            Self::ReadPackage => "read_package",
            Self::CreateTarget => "create_target",
            Self::SelectTarget => "select_target",
            Self::OpenWriter => "open_writer",
            Self::WriteDocument => "write_document",
            Self::CloseWriter => "close_writer",
        }
    }
}

/// Static diagnostics only: never retain a document, job title, or printer name.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PrintError {
    pub stage: PrintStage,
    pub native_code: Option<i32>,
    pub cancel_code: Option<i32>,
}

impl PrintError {
    fn new(stage: PrintStage) -> Self {
        Self {
            stage,
            native_code: None,
            cancel_code: None,
        }
    }

    #[cfg(windows)]
    fn native(stage: PrintStage, error: windows::core::Error) -> Self {
        Self {
            native_code: Some(error.code().0),
            ..Self::new(stage)
        }
    }
}

impl fmt::Display for PrintError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "print stage={}", self.stage.code())?;
        if let Some(code) = self.native_code {
            write!(formatter, " hresult={:#010x}", code as u32)?;
        }
        if let Some(code) = self.cancel_code {
            write!(formatter, " cancel_hresult={:#010x}", code as u32)?;
        }
        Ok(())
    }
}

impl Error for PrintError {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PrintSubmission {
    pub documents: u32,
    pub pages: u32,
}

/// Checked before COM initialization, allocation, or a spooler side effect.
pub fn validate_request(printer_name: &str, document: &[u8]) -> Result<(), PrintError> {
    if printer_name.is_empty()
        || printer_name.contains('\0')
        || printer_name.encode_utf16().count() > MAX_PRINTER_NAME_UNITS
        || document.is_empty()
        || document.len() > MAX_DOCUMENT_BYTES
    {
        return Err(PrintError::new(PrintStage::ValidateRequest));
    }
    Ok(())
}

#[cfg(any(windows, test))]
fn decode_default_printer(buffer: &[u16], reported: u32) -> Result<String, PrintError> {
    let error = || PrintError::new(PrintStage::ResolveDefaultPrinter);
    if !(2..=MAX_PRINTER_NAME_UNITS + 1).contains(&(reported as usize)) {
        return Err(error());
    }
    let name = buffer.get(..reported as usize).ok_or_else(error)?;
    if name.last() != Some(&0) || name[..name.len() - 1].contains(&0) {
        return Err(error());
    }
    String::from_utf16(&name[..name.len() - 1]).map_err(|_| error())
}

#[cfg(any(windows, test))]
fn valid_advisory_dimension(value: f32) -> bool {
    value == -1.0 || (value.is_finite() && value >= 1.0)
}

#[cfg(any(windows, test))]
trait PackageBackend {
    fn prepare(&mut self, document: &[u8]) -> Result<PrintSubmission, PrintError>;
    fn create_target(&mut self, printer_name: &str) -> Result<(), PrintError>;
    fn select_target(&mut self) -> Result<(), PrintError>;
    fn open_writer(&mut self) -> Result<(), PrintError>;
    fn write_document(&mut self) -> Result<(), PrintError>;
    fn close_writer(&mut self) -> Result<(), PrintError>;
    /// No-op if no job exists; otherwise cancel exactly once, including unwinds.
    fn cancel(&mut self) -> Result<(), i32>;
}

#[cfg(any(windows, test))]
struct PendingSubmission<'a, B: PackageBackend> {
    backend: &'a mut B,
    settled: bool,
}

#[cfg(any(windows, test))]
impl<B: PackageBackend> Drop for PendingSubmission<'_, B> {
    fn drop(&mut self) {
        if !self.settled {
            // A backend must also report a failed best-effort cancel through its
            // bounded diagnostics. Normal errors return the cancel HRESULT.
            let _ = self.backend.cancel();
        }
    }
}

#[cfg(any(windows, test))]
fn submit_with_backend<B: PackageBackend>(
    printer_name: &str,
    document: &[u8],
    backend: &mut B,
) -> Result<PrintSubmission, PrintError> {
    validate_request(printer_name, document)?;
    let manifest = backend.prepare(document)?;
    if manifest.documents == 0
        || manifest.documents > MAX_DOCUMENTS
        || manifest.pages == 0
        || manifest.pages > MAX_PAGES
    {
        return Err(PrintError::new(PrintStage::ReadPackage));
    }
    let mut pending = PendingSubmission {
        backend,
        settled: false,
    };
    let outcome = (|| {
        pending.backend.create_target(printer_name)?;
        pending.backend.select_target()?;
        pending.backend.open_writer()?;
        pending.backend.write_document()?;
        pending.backend.close_writer()
    })();
    if let Err(mut error) = outcome {
        error.cancel_code = pending.backend.cancel().err();
        pending.settled = true;
        return Err(error);
    }
    pending.settled = true;
    Ok(manifest)
}

#[cfg(windows)]
mod native;

#[cfg(windows)]
pub use native::submit_xps;

#[cfg(test)]
mod tests;
