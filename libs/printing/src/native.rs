use super::{
    decode_default_printer, submit_with_backend, valid_advisory_dimension, validate_request,
    PackageBackend, PrintError, PrintStage, PrintSubmission, MAX_DOCUMENTS, MAX_PAGES,
    MAX_PRINTER_NAME_UNITS,
};
use std::{collections::HashSet, ffi::c_void, marker::PhantomData, ptr, rc::Rc};
use windows::{
    core::{w, Interface, GUID, HRESULT, PCWSTR, PWSTR},
    Win32::{
        Foundation::{GetLastError, ERROR_INSUFFICIENT_BUFFER, E_INVALIDARG, E_OUTOFMEMORY},
        Graphics::Printing::GetDefaultPrinterW,
        Storage::{
            Packaging::Opc::IOpcPartUri,
            Xps::{
                IXpsDocumentPackageTarget, IXpsOMDocumentStructureResource, IXpsOMImageResource,
                IXpsOMObjectFactory1, IXpsOMPackage1, IXpsOMPackageWriter, IXpsOMPage,
                IXpsOMPartUriCollection, IXpsOMPrintTicketResource, IXpsOMStoryFragmentsResource,
                Printing::{
                    IPrintDocumentPackageTarget, IPrintDocumentPackageTargetFactory,
                    PrintDocumentPackageTargetFactory, ID_DOCUMENTPACKAGETARGET_MSXPS,
                    ID_DOCUMENTPACKAGETARGET_OPENXPS,
                },
                XpsOMObjectFactory, XPS_FONT_EMBEDDING_RESTRICTED,
                XPS_FONT_EMBEDDING_RESTRICTED_UNOBFUSCATED, XPS_SIZE,
            },
        },
        System::Com::{
            CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, IStream,
            CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
        },
        UI::Shell::SHCreateMemStream,
    },
};

/// Submit either MSXPS or OpenXPS using Windows' document-package API.
///
/// This is synchronous and must run on an owned blocking worker, never a UI or
/// async runtime thread. It does not wait for physical printing, retry, choose a
/// different printer, or load a DLL from an application/writable search path.
pub fn submit_xps(
    printer_name: Option<&str>,
    document: &[u8],
) -> Result<PrintSubmission, PrintError> {
    // Check bytes and any explicit target before even querying a default.
    let explicit = printer_name.filter(|name| !name.is_empty());
    validate_request(explicit.unwrap_or("default"), document)?;
    let default_name;
    let printer_name = match explicit {
        Some(name) => name,
        None => {
            default_name = resolve_default_printer()?;
            &default_name
        }
    };
    let _apartment = Apartment::initialize()?;
    submit_with_backend(printer_name, document, &mut NativeBackend::default())
}

fn resolve_default_printer() -> Result<String, PrintError> {
    let mut required = 0u32;
    let probe = unsafe { GetDefaultPrinterW(None, &mut required) };
    let code = unsafe { GetLastError() };
    if probe.as_bool() {
        return Err(PrintError::new(PrintStage::ResolveDefaultPrinter));
    }
    if code != ERROR_INSUFFICIENT_BUFFER {
        return Err(PrintError::native(
            PrintStage::ResolveDefaultPrinter,
            windows::core::Error::from_hresult(HRESULT::from_win32(code.0)),
        ));
    }
    if !(2..=MAX_PRINTER_NAME_UNITS as u32 + 1).contains(&required) {
        return Err(PrintError::new(PrintStage::ResolveDefaultPrinter));
    }
    let mut buffer = vec![0u16; required as usize];
    // Lengths are UTF-16 units including the trailing NUL. Buffer growth or a
    // failed second query fails instead of selecting a fallback destination.
    if !unsafe { GetDefaultPrinterW(Some(PWSTR(buffer.as_mut_ptr())), &mut required) }.as_bool() {
        return Err(PrintError::native(
            PrintStage::ResolveDefaultPrinter,
            windows::core::Error::from_win32(),
        ));
    }
    decode_default_printer(&buffer, required)
}

struct Apartment(PhantomData<Rc<()>>);

impl Apartment {
    fn initialize() -> Result<Self, PrintError> {
        // S_FALSE is also success and requires a balancing CoUninitialize.
        // RPC_E_CHANGED_MODE is a real failure, not permission to retry an
        // incompatible apartment or uninitialize somebody else's COM context.
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
            .ok()
            .map_err(|error| PrintError::native(PrintStage::InitializeCom, error))?;
        Ok(Self(PhantomData))
    }
}

impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}

struct PreparedPage {
    page: IXpsOMPage,
    dimensions: XPS_SIZE,
    ticket: Option<IXpsOMPrintTicketResource>,
    story: Option<IXpsOMStoryFragmentsResource>,
    thumbnail: Option<IXpsOMImageResource>,
}

struct PreparedDocument {
    part_name: IOpcPartUri,
    ticket: Option<IXpsOMPrintTicketResource>,
    structure: Option<IXpsOMDocumentStructureResource>,
    restricted_fonts: IXpsOMPartUriCollection,
    pages: Vec<PreparedPage>,
}

struct PreparedPackage {
    // Keep source objects/stream alive through all lazy resource reads.
    _package: IXpsOMPackage1,
    _source: IStream,
    sequence_name: IOpcPartUri,
    job_ticket: Option<IStream>,
    documents: Vec<PreparedDocument>,
}

#[derive(Default)]
struct NativeBackend {
    prepared: Option<PreparedPackage>,
    target: Option<IPrintDocumentPackageTarget>,
    xps_target: Option<IXpsDocumentPackageTarget>,
    writer: Option<IXpsOMPackageWriter>,
}

// windows-rs convenience getters turn S_OK + NULL into E_POINTER, even for
// resources documented as optional. Read the raw out parameter so an absent
// ticket is distinct from an actual parse/HRESULT error. Never use `.ok()` to
// discard malformed print tickets or other resource failures.
unsafe fn optional_interface<T: Interface>(
    get: impl FnOnce(*mut *mut c_void) -> HRESULT,
) -> windows::core::Result<Option<T>> {
    let mut value = ptr::null_mut();
    get(&mut value).ok()?;
    Ok(if value.is_null() {
        None
    } else {
        Some(unsafe { T::from_raw(value) })
    })
}

macro_rules! optional_resource {
    ($object:expr, $method:ident, $interface:ty) => {{
        let object = &$object;
        optional_interface::<$interface>(|out| {
            (Interface::vtable(object).$method)(Interface::as_raw(object), out)
        })
    }};
}

fn invalid_package() -> windows::core::Error {
    windows::core::Error::from_hresult(E_INVALIDARG)
}

impl NativeBackend {
    unsafe fn prepare_package(
        &mut self,
        document: &[u8],
    ) -> windows::core::Result<PrintSubmission> {
        let source = unsafe { SHCreateMemStream(Some(document)) }
            .ok_or_else(|| windows::core::Error::from_hresult(E_OUTOFMEMORY))?;
        let factory: IXpsOMObjectFactory1 =
            unsafe { CoCreateInstance(&XpsOMObjectFactory, None, CLSCTX_INPROC_SERVER) }?;
        // Unlike CreatePackageFromStream, this supports both MSXPS and OpenXPS.
        let package = unsafe { factory.CreatePackageFromStream1(&source, false) }?;
        let sequence = unsafe { package.GetDocumentSequence() }?;
        let input_documents = unsafe { sequence.GetDocuments() }?;
        let document_count = unsafe { input_documents.GetCount() }?;
        if document_count == 0 || document_count > MAX_DOCUMENTS {
            return Err(invalid_package());
        }
        let job_ticket = unsafe {
            optional_resource!(sequence, GetPrintTicketResource, IXpsOMPrintTicketResource)?
        };
        let job_ticket = job_ticket
            .as_ref()
            .map(|ticket| unsafe { ticket.GetStream() })
            .transpose()?;
        let mut documents = Vec::with_capacity(document_count as usize);
        let mut total_pages = 0u32;
        for index in 0..document_count {
            let document = unsafe { input_documents.GetAt(index) }?;
            let references = unsafe { document.GetPageReferences() }?;
            let count = unsafe { references.GetCount() }?;
            total_pages = total_pages.checked_add(count).ok_or_else(invalid_package)?;
            if count == 0 || total_pages > MAX_PAGES {
                return Err(invalid_package());
            }
            let mut pages = Vec::with_capacity(count as usize);
            let restricted_fonts = unsafe { factory.CreatePartUriCollection() }?;
            let mut restricted_names = HashSet::new();
            for index in 0..count {
                let reference = unsafe { references.GetAt(index) }?;
                let dimensions = unsafe { reference.GetAdvisoryPageDimensions() }?;
                // -1 is explicitly valid: that advisory dimension is unset.
                if !valid_advisory_dimension(dimensions.width)
                    || !valid_advisory_dimension(dimensions.height)
                {
                    return Err(invalid_package());
                }
                let page = unsafe { reference.GetPage() }?;
                let actual = unsafe { page.GetPageDimensions() }?;
                if !actual.width.is_finite()
                    || !actual.height.is_finite()
                    || actual.width < 1.0
                    || actual.height < 1.0
                {
                    return Err(invalid_package());
                }
                let resources = unsafe { reference.CollectPartResources() }?;
                let fonts = unsafe { resources.GetFontResources() }?;
                let font_count = unsafe { fonts.GetCount() }?;
                if font_count > 16384 {
                    return Err(invalid_package());
                }
                for index in 0..font_count {
                    let font = unsafe { fonts.GetAt(index) }?;
                    let embedding = unsafe { font.GetEmbeddingOption() }?;
                    if embedding == XPS_FONT_EMBEDDING_RESTRICTED_UNOBFUSCATED {
                        // Malformed producer output must not remove a font's
                        // restriction or be silently re-embedded unrestricted.
                        return Err(invalid_package());
                    }
                    if embedding == XPS_FONT_EMBEDDING_RESTRICTED {
                        let part_name = unsafe { font.GetPartName() }?;
                        let name = unsafe { part_name.GetAbsoluteUri() }?.to_string();
                        if restricted_names.insert(name) {
                            if restricted_names.len() > 16384 {
                                return Err(invalid_package());
                            }
                            unsafe { restricted_fonts.Append(&part_name) }?;
                        }
                    }
                }
                // Parse every page before creating a system print job. This
                // does not claim a decompressed-resource memory budget; that
                // needs the supervised worker boundary, not a compressed cap.
                pages.push(PreparedPage {
                    page,
                    dimensions,
                    ticket: unsafe {
                        optional_resource!(
                            reference,
                            GetPrintTicketResource,
                            IXpsOMPrintTicketResource
                        )?
                    },
                    story: unsafe {
                        optional_resource!(
                            reference,
                            GetStoryFragmentsResource,
                            IXpsOMStoryFragmentsResource
                        )?
                    },
                    thumbnail: unsafe {
                        optional_resource!(reference, GetThumbnailResource, IXpsOMImageResource)?
                    },
                });
            }
            documents.push(PreparedDocument {
                part_name: unsafe { document.GetPartName() }?,
                ticket: unsafe {
                    optional_resource!(document, GetPrintTicketResource, IXpsOMPrintTicketResource)?
                },
                structure: unsafe {
                    optional_resource!(
                        document,
                        GetDocumentStructureResource,
                        IXpsOMDocumentStructureResource
                    )?
                },
                restricted_fonts,
                pages,
            });
        }
        self.prepared = Some(PreparedPackage {
            sequence_name: unsafe { sequence.GetPartName() }?,
            job_ticket,
            documents,
            _package: package,
            _source: source,
        });
        Ok(PrintSubmission {
            documents: document_count,
            pages: total_pages,
        })
    }

    unsafe fn choose_target(&mut self) -> windows::core::Result<()> {
        let target = self.target.as_ref().ok_or_else(invalid_package)?;
        let mut count = 0u32;
        let mut raw = ptr::null_mut();
        let result = unsafe { target.GetPackageTargetTypes(&mut count, &mut raw) };
        let types = TargetTypes(raw);
        result?;
        if count == 0 || count > 64 || types.0.is_null() {
            return Err(invalid_package());
        }
        let supported = unsafe { std::slice::from_raw_parts(types.0, count as usize) };
        // Preserve the driver's preference order. The OM-to-package path is
        // responsible for MSXPS/OpenXPS conversion, never a raw stream cast.
        let selected = supported
            .iter()
            .find(|id| {
                **id == ID_DOCUMENTPACKAGETARGET_OPENXPS || **id == ID_DOCUMENTPACKAGETARGET_MSXPS
            })
            .ok_or_else(invalid_package)?;
        self.xps_target = Some(unsafe { target.GetPackageTarget(selected) }?);
        Ok(())
    }

    unsafe fn write_pages(&self) -> windows::core::Result<()> {
        let package = self.prepared.as_ref().ok_or_else(invalid_package)?;
        let writer = self.writer.as_ref().ok_or_else(invalid_package)?;
        for document in &package.documents {
            unsafe {
                // This is a new print rendition, not a signed-file copy. Do not
                // propagate signatures that cannot authenticate the new package.
                writer.StartNewDocument(
                    &document.part_name,
                    document.ticket.as_ref(),
                    document.structure.as_ref(),
                    None,
                    &document.restricted_fonts,
                )?;
            }
            for page in &document.pages {
                unsafe {
                    writer.AddPage(
                        &page.page,
                        &page.dimensions,
                        None,
                        page.story.as_ref(),
                        page.ticket.as_ref(),
                        page.thumbnail.as_ref(),
                    )?;
                }
            }
        }
        Ok(())
    }
}

struct TargetTypes(*mut GUID);

impl Drop for TargetTypes {
    fn drop(&mut self) {
        unsafe { CoTaskMemFree(Some(self.0.cast())) };
    }
}

impl PackageBackend for NativeBackend {
    fn prepare(&mut self, document: &[u8]) -> Result<PrintSubmission, PrintError> {
        unsafe { self.prepare_package(document) }
            .map_err(|error| PrintError::native(PrintStage::ReadPackage, error))
    }

    fn create_target(&mut self, printer_name: &str) -> Result<(), PrintError> {
        let create = || -> windows::core::Result<_> {
            let factory: IPrintDocumentPackageTargetFactory = unsafe {
                CoCreateInstance(
                    &PrintDocumentPackageTargetFactory,
                    None,
                    CLSCTX_INPROC_SERVER,
                )
            }?;
            let name: Vec<u16> = printer_name.encode_utf16().chain(Some(0)).collect();
            let package = self.prepared.as_ref().ok_or_else(invalid_package)?;
            unsafe {
                factory.CreateDocumentPackageTargetForPrintJob(
                    PCWSTR(name.as_ptr()),
                    w!("Camellia Remote print"),
                    None,
                    package.job_ticket.as_ref(),
                )
            }
        };
        self.target =
            Some(create().map_err(|error| PrintError::native(PrintStage::CreateTarget, error))?);
        Ok(())
    }

    fn select_target(&mut self) -> Result<(), PrintError> {
        unsafe { self.choose_target() }
            .map_err(|error| PrintError::native(PrintStage::SelectTarget, error))
    }

    fn open_writer(&mut self) -> Result<(), PrintError> {
        let open = || -> windows::core::Result<_> {
            let target = self.xps_target.as_ref().ok_or_else(invalid_package)?;
            let package = self.prepared.as_ref().ok_or_else(invalid_package)?;
            unsafe { target.GetXpsOMPackageWriter(&package.sequence_name, None) }
        };
        self.writer =
            Some(open().map_err(|error| PrintError::native(PrintStage::OpenWriter, error))?);
        Ok(())
    }

    fn write_document(&mut self) -> Result<(), PrintError> {
        unsafe { self.write_pages() }
            .map_err(|error| PrintError::native(PrintStage::WriteDocument, error))
    }

    fn close_writer(&mut self) -> Result<(), PrintError> {
        let writer = self
            .writer
            .as_ref()
            .ok_or_else(|| PrintError::new(PrintStage::CloseWriter))?;
        unsafe { writer.Close() }
            .map_err(|error| PrintError::native(PrintStage::CloseWriter, error))
    }

    fn cancel(&mut self) -> Result<(), i32> {
        let result = self.target.take().map(|target| unsafe { target.Cancel() });
        self.writer.take();
        self.xps_target.take();
        match result {
            Some(Err(error)) => {
                let code = error.code().0;
                log::error!("print stage=cancel hresult={:#010x}", code as u32);
                Err(code)
            }
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::{
        Foundation::E_FAIL,
        Storage::Xps::{XPS_DOCUMENT_TYPE, XPS_DOCUMENT_TYPE_OPENXPS, XPS_DOCUMENT_TYPE_XPS},
        System::Com::{ISequentialStream, STATFLAG_NONAME, STATSTG, STREAM_SEEK_SET},
    };

    fn source_package(document_type: XPS_DOCUMENT_TYPE) -> Vec<u8> {
        // Build our own tiny, blank-page document through the OS object model;
        // no captured user document, external sample, or printer is needed.
        unsafe {
            let factory: IXpsOMObjectFactory1 =
                CoCreateInstance(&XpsOMObjectFactory, None, CLSCTX_INPROC_SERVER).unwrap();
            let package = factory.CreatePackage().unwrap();
            let sequence = factory
                .CreateDocumentSequence(
                    &factory
                        .CreatePartUri(w!("/FixedDocumentSequence.fdseq"))
                        .unwrap(),
                )
                .unwrap();
            let document = factory
                .CreateDocument(
                    &factory
                        .CreatePartUri(w!("/Documents/1/FixedDocument.fdoc"))
                        .unwrap(),
                )
                .unwrap();
            let page = factory
                .CreatePage(
                    &XPS_SIZE {
                        width: 816.0,
                        height: 1056.0,
                    },
                    w!("en-US"),
                    &factory
                        .CreatePartUri(w!("/Documents/1/Pages/1.fpage"))
                        .unwrap(),
                )
                .unwrap();
            let reference = factory
                .CreatePageReference(&XPS_SIZE {
                    width: -1.0,
                    height: -1.0,
                })
                .unwrap();
            reference.SetPage(&page).unwrap();
            document
                .GetPageReferences()
                .unwrap()
                .Append(&reference)
                .unwrap();
            sequence.GetDocuments().unwrap().Append(&document).unwrap();
            package.SetDocumentSequence(&sequence).unwrap();
            let stream = SHCreateMemStream(None).unwrap();
            package
                .cast::<IXpsOMPackage1>()
                .unwrap()
                .WriteToStream1(
                    &stream.cast::<ISequentialStream>().unwrap(),
                    false,
                    document_type,
                )
                .unwrap();
            let mut info = STATSTG::default();
            stream.Stat(&mut info, STATFLAG_NONAME).unwrap();
            assert!(info.cbSize > 0 && info.cbSize < 1024 * 1024);
            stream.Seek(0, STREAM_SEEK_SET, None).unwrap();
            let mut bytes = vec![0u8; info.cbSize as usize];
            let mut read = 0;
            stream
                .Read(
                    bytes.as_mut_ptr().cast(),
                    bytes.len() as u32,
                    Some(&mut read),
                )
                .ok()
                .unwrap();
            assert_eq!(read as usize, bytes.len());
            bytes
        }
    }

    #[test]
    fn actual_msxps_and_openxps_parse_without_creating_system_print_jobs() {
        let _apartment = Apartment::initialize().unwrap();
        for kind in [XPS_DOCUMENT_TYPE_XPS, XPS_DOCUMENT_TYPE_OPENXPS] {
            let data = source_package(kind);
            let mut backend = NativeBackend::default();
            assert_eq!(
                backend.prepare(&data).unwrap(),
                PrintSubmission {
                    documents: 1,
                    pages: 1
                }
            );
            let prepared = backend.prepared.as_ref().unwrap();
            assert!(prepared.job_ticket.is_none());
            assert!(prepared.documents[0].ticket.is_none());
            assert!(prepared.documents[0].pages[0].ticket.is_none());
            assert_eq!(
                unsafe { prepared.documents[0].restricted_fonts.GetCount() }.unwrap(),
                0
            );
            assert!(backend.target.is_none());
            assert!(backend.writer.is_none());
        }
    }

    #[test]
    fn malformed_package_fails_before_a_system_print_job_can_exist() {
        let _apartment = Apartment::initialize().unwrap();
        let mut backend = NativeBackend::default();
        assert_eq!(
            submit_with_backend(
                "not-an-installed-printer",
                b"not-an-xps-package",
                &mut backend
            )
            .unwrap_err()
            .stage,
            PrintStage::ReadPackage
        );
        assert!(backend.target.is_none());
        assert!(backend.writer.is_none());
    }

    #[test]
    fn optional_resource_null_is_not_a_parse_failure() {
        let absent = unsafe { optional_interface::<IStream>(|_| HRESULT(0)) }.unwrap();
        assert!(absent.is_none());
        let error = unsafe { optional_interface::<IStream>(|_| E_FAIL) }.unwrap_err();
        assert_eq!(error.code(), E_FAIL);
    }

    #[test]
    fn rejected_request_never_initializes_com_or_touches_a_printer() {
        assert_eq!(
            submit_xps(Some("queue\0other"), b"not-xps")
                .unwrap_err()
                .stage,
            PrintStage::ValidateRequest
        );
    }

    #[test]
    fn apartment_initialization_is_balanced_on_reentry_without_printing() {
        let first = Apartment::initialize().unwrap();
        let second = Apartment::initialize().unwrap();
        drop(second);
        drop(first);
        drop(Apartment::initialize().unwrap());
    }
}
