use super::*;

type Client = ScreenCaptureServiceClient<Box<dyn idevice::ReadWrite>>;

#[derive(Default)]
pub(super) struct CaptureSession {
    client: Option<Client>,
}
impl CaptureSession {
    pub(super) async fn take(
        &mut self, a: &mut AdapterHandle, r: &mut RsdHandshake,
    ) -> Result<Vec<u8>, String> {
        let started = Instant::now();
        let reused = self.client.is_some();
        // Keep the client out of self while an operation is cancellable. An
        // interrupted protocol exchange must never be reused by the next call.
        let mut client = match self.client.take() {
            Some(client) => client,
            None => bounded("screenshot_service", 15, Client::connect_rsd(a, r)).await?,
        };
        let connect_ms = started.elapsed().as_millis() as u64;
        let capture_started = Instant::now();
        let mut result = bounded("screenshot_capture", 15, client.take_screenshot(None, ImageFormat::Png)).await;
        let mut reconnected = false;
        if result.is_err() && reused && !CANCEL.load(Ordering::Acquire) {
            // Only repeat a read-only capture, never a phone mutation.
            client = bounded("screenshot_service", 15, Client::connect_rsd(a, r)).await?;
            reconnected = true;
            result = bounded("screenshot_capture", 15, client.take_screenshot(None, ImageFormat::Png)).await;
        }
        let png = result?;
        dimensions(&png)?;
        self.client = Some(client);
        event("capture_metrics", json!({
            "reused_connection": reused, "reconnected": reconnected,
            "connect_ms": connect_ms, "capture_ms": capture_started.elapsed().as_millis() as u64,
            "elapsed_ms": started.elapsed().as_millis() as u64, "png_bytes": png.len(),
        }));
        Ok(png)
    }
}

pub(super) fn dimensions(png: &[u8]) -> Result<(u32, u32), String> {
    if png.len() < 24 || png.len() > 64 * 1024 * 1024 || &png[..8] != b"\x89PNG\r\n\x1a\n" || &png[12..16] != b"IHDR" {
        return Err("Invalid screenshot PNG".into());
    }
    let width = u32::from_be_bytes(png[16..20].try_into().unwrap());
    let height = u32::from_be_bytes(png[20..24].try_into().unwrap());
    if width == 0 || height == 0 || width > 20_000 || height > 20_000 {
        return Err("Invalid screenshot dimensions".into());
    }
    Ok((width, height))
}

// One immutable frame at a time; retrieval is tied to its unique capture ID.
// It crosses the C boundary as bytes, never as base64 JSON or a scratch file.
#[derive(Default)]
struct FrameBuffer(Option<(String, Vec<u8>)>);
impl FrameBuffer {
    fn take(&mut self, id: &str) -> Option<Vec<u8>> {
        if self.0.as_ref().is_some_and(|(key, _)| key == id) {
            self.0.take().map(|(_, bytes)| bytes)
        } else { None }
    }
}
static FRAME: OnceLock<Mutex<FrameBuffer>> = OnceLock::new();
pub(super) fn store(id: String, png: Vec<u8>) {
    FRAME.get_or_init(Default::default).lock().unwrap().0 = Some((id, png));
}
pub(super) fn clear() { FRAME.get_or_init(Default::default).lock().unwrap().0 = None; }

/// The caller supplies a UTF-8 frame ID and valid output-length pointer.
/// Return ownership exactly once using solo_frame_free with the returned length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn solo_take_frame(id: *const c_char, length: *mut usize) -> *mut u8 {
    if id.is_null() || length.is_null() { return std::ptr::null_mut(); }
    unsafe { *length = 0; }
    let Ok(id) = (unsafe { CStr::from_ptr(id) }).to_str() else { return std::ptr::null_mut(); };
    let Some(bytes) = FRAME.get_or_init(Default::default).lock().unwrap().take(id) else { return std::ptr::null_mut(); };
    let boxed = bytes.into_boxed_slice();
    unsafe { *length = boxed.len(); }
    Box::into_raw(boxed).cast::<u8>()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn solo_frame_free(bytes: *mut u8, length: usize) {
    if !bytes.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes, length)) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn transferred_bytes_survive_session_clear_and_are_freed_once() {
        let id = CString::new("ffi-fixture").unwrap();
        let original = vec![1, 2, 3, 4];
        store("ffi-fixture".into(), original.clone());
        let mut length = 0;
        let bytes = unsafe { solo_take_frame(id.as_ptr(), &mut length) };
        assert!(!bytes.is_null());
        clear();
        assert_eq!(unsafe { std::slice::from_raw_parts(bytes, length) }, original);
        unsafe { solo_frame_free(bytes, length); }
        assert!(unsafe { solo_take_frame(id.as_ptr(), &mut length) }.is_null());
        assert_eq!(length, 0);
    }
    #[test]
    fn frame_ownership_is_matched_and_one_shot() {
        let mut frame = FrameBuffer(Some(("new".into(), vec![1, 2, 3])));
        assert_eq!(frame.take("old"), None);
        assert_eq!(frame.take("new"), Some(vec![1, 2, 3]));
        assert_eq!(frame.take("new"), None);
    }
    #[test]
    fn png_geometry_rejects_incomplete_and_invalid_headers() {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend(1320u32.to_be_bytes()); png.extend(2868u32.to_be_bytes());
        assert_eq!(dimensions(&png), Ok((1320, 2868)));
        assert!(dimensions(&png[..23]).is_err());
        png[16..20].copy_from_slice(&0u32.to_be_bytes());
        assert!(dimensions(&png).is_err());
    }
}
