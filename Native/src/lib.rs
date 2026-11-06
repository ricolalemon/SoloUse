//! SoloUse hardware feasibility probe. No cloud, model, or network command server.
//! Protocol support is supplied by the pinned MIT-licensed idevice dependency.
use idevice::{
    RsdService,
    core_device::{
        AppServiceClient, ButtonState, CallInfoBlob, DisplayServiceClient, ImageFormat,
        IndigoHidClient, KeyboardUsage, RtpPacket, ScreenCaptureServiceClient,
        UniversalHidServiceClient, build_frame_ack, build_liveness, build_rctl,
        build_screen_audio_offer, build_screen_video_offer, build_start_audio_parameters,
        build_start_video_parameters, is_rtcp,
    },
    remote_pairing::{
        PairableHost, PairableHostInfo, RemotePairingClient, RpPairingFile, RpPairingSocket,
        connect_tls_psk_tunnel_native,
    },
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV6};
use std::{
    collections::VecDeque,
    ffi::{CStr, CString, c_char},
    future::Future,
    path::PathBuf,
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::net::{TcpListener, TcpStream};
mod accessibility;
mod clipboard;
mod capture;
mod media;
mod phone;

static RUNNING: AtomicBool = AtomicBool::new(false);
static CANCEL: AtomicBool = AtomicBool::new(false);
static EVENTS: OnceLock<Mutex<VecDeque<Value>>> = OnceLock::new();

#[derive(Deserialize)]
struct Config {
    mode: String,
    directory: PathBuf,
    #[serde(default = "default_bundle_prefix")]
    bundle_prefix: String,
    #[serde(default = "default_host")]
    host: String,
    #[serde(default = "default_port")]
    port: u16,
    #[serde(default)]
    x: f64,
    #[serde(default)]
    y: f64,
    #[serde(default = "default_background_seconds")]
    background_seconds: u64,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default = "default_read_only")]
    read_only: bool,
    #[serde(default)]
    keyboard_tuning: KeyboardTuning,
}
#[derive(Clone, Copy, Deserialize)]
#[serde(default)]
struct KeyboardTuning {
    setup_ms: u64,
    paste_ms: u64,
    keep_connected: bool,
    indigo: bool,
    paste_indigo: bool,
}
impl Default for KeyboardTuning {
    fn default() -> Self { Self { setup_ms: 100, paste_ms: 500, keep_connected: false, indigo: true, paste_indigo: true } }
}
fn default_bundle_prefix() -> String { "dev.solouse".into() }
fn default_host() -> String {
    "10.7.0.1".into()
}
fn default_port() -> u16 {
    49152
}
fn default_background_seconds() -> u64 {
    300
}
fn default_read_only() -> bool {
    true
}

fn event(kind: &str, mut data: Value) {
    data["kind"] = kind.into();
    data["native_timestamp_ms"] = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64)
        .into();
    let mut q = EVENTS.get_or_init(Default::default).lock().unwrap();
    if q.len() >= 300 {
        if let Some(index) = q
            .iter()
            .position(|e| matches!(e["kind"].as_str(), Some("stream" | "phase" | "screenshot")))
        {
            q.remove(index);
        } else if matches!(kind, "stream" | "phase" | "screenshot") {
            return;
        }
    }
    q.push_back(data);
}
fn phase(name: &str) {
    event("phase", json!({"stage": name}));
}

async fn bounded<T, E: std::fmt::Display>(
    name: &str,
    seconds: u64,
    future: impl Future<Output = Result<T, E>>,
) -> Result<T, String> {
    phase(name);
    let outcome = tokio::select! {
        value = tokio::time::timeout(Duration::from_secs(seconds), future) => value,
        _ = cancellation() => return Err("Cancelled by user or system".into()),
    };
    match outcome {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(format!("{name}: {error}")),
        Err(_) => Err(format!("{name}: timeout after {seconds}s")),
    }
}
async fn cancellation() {
    while !CANCEL.load(Ordering::Acquire) {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn validate(c: &Config) -> Result<(), String> {
    if c.bundle_prefix.is_empty() || c.bundle_prefix.len() > 180 || c.bundle_prefix.starts_with('.')
        || c.bundle_prefix.ends_with('.') || c.bundle_prefix.contains("..")
        || !c.bundle_prefix.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-') {
        return Err("Invalid application bundle prefix".into());
    }
    if c.keyboard_tuning.setup_ms > 2000 || c.keyboard_tuning.paste_ms > 5000 {
        return Err("Invalid keyboard timing".into());
    }
    if ![
        "pair",
        "probe",
        "touch",
        "background",
        "direct_probe",
        "tree_probe",
        "tree_fixture",
        "session",
    ]
    .contains(&c.mode.as_str())
    {
        return Err("Unknown mode".into());
    }
    if !c.directory.is_absolute() {
        return Err("Private storage must be absolute".into());
    }
    // The probe is deliberately constrained to its own device's loopback routes.
    if c.host != "10.7.0.1" && c.host != "127.0.0.1" {
        return Err("Only local loopback endpoints are supported".into());
    }
    if c.port == 0 {
        return Err("Invalid local developer service port".into());
    }
    if c.mode == "background" && !(60..=1800).contains(&c.background_seconds) {
        return Err("Background test must last 60–1800 seconds".into());
    }
    if c.mode == "touch"
        && (!c.x.is_finite()
            || !c.y.is_finite()
            || !(0.05..=0.95).contains(&c.x)
            || !(0.05..=0.95).contains(&c.y))
    {
        return Err("Invalid test target coordinates".into());
    }
    if c.mode == "session"
        && c.session_id
            .as_deref()
            .is_none_or(|id| uuid::Uuid::parse_str(id).is_err())
    {
        return Err("A valid session id is required".into());
    }
    Ok(())
}

/// The caller owns and NUL-terminates `configuration_json` for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn solo_start(configuration_json: *const c_char) -> i32 {
    if configuration_json.is_null() {
        return -1;
    }
    let Ok(s) = (unsafe { CStr::from_ptr(configuration_json) }).to_str() else {
        return -1;
    };
    let Ok(config) = serde_json::from_str::<Config>(s) else {
        return -1;
    };
    if let Err(e) = validate(&config) {
        event("error", json!({"message": e}));
        return -1;
    }
    if RUNNING
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return -2;
    }
    CANCEL.store(false, Ordering::Release);
    phone::reset();
    std::thread::spawn(move || {
        let result = std::panic::catch_unwind(|| {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|e| e.to_string())?;
            runtime.block_on(async {
                match config.mode.as_str() {
                    "pair" => pair(&config).await,
                    "direct_probe" => direct_probe(&config).await,
                    "session" => phone::run(&config).await,
                    "tree_probe" => accessibility::probe(&config).await,
                    "tree_fixture" => accessibility::fixture(&config).await,
                    _ => probe(&config).await,
                }
            })
        });
        phone::reset();
        RUNNING.store(false, Ordering::Release);
        match result {
            Ok(Ok(())) => event("finished", json!({"ok": true})),
            Ok(Err(e)) => {
                event("error", json!({"message": e}));
                event("finished", json!({"ok": false}));
            }
            Err(_) => {
                event(
                    "error",
                    json!({"message": "Native worker stopped unexpectedly"}),
                );
                event("finished", json!({"ok": false}));
            }
        }
    });
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn solo_poll() -> *mut c_char {
    let value = EVENTS
        .get_or_init(Default::default)
        .lock()
        .unwrap()
        .pop_front();
    value
        .and_then(|v| CString::new(v.to_string()).ok())
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn solo_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn solo_cancel() {
    CANCEL.store(true, Ordering::Release);
}
#[unsafe(no_mangle)]
pub extern "C" fn solo_is_running() -> i32 {
    i32::from(RUNNING.load(Ordering::Acquire))
}

fn private_write(path: &std::path::Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let tmp = path.with_extension("pending");
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| e.to_string())?;
    f.write_all(bytes).map_err(|e| e.to_string())?;
    f.sync_all().map_err(|e| e.to_string())?;
    std::fs::rename(tmp, path).map_err(|e| e.to_string())
}

async fn pair(c: &Config) -> Result<(), String> {
    let record_path = c.directory.join("pairing.plist");
    let mut record = if record_path.exists() {
        RpPairingFile::from_bytes(&std::fs::read(&record_path).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?
    } else {
        RpPairingFile::generate(&format!("SoloUse-{}", uuid::Uuid::new_v4()))
    };
    if record.alt_irk.is_some() {
        return Err("A pairing already exists; it will not be replaced automatically".into());
    }
    private_write(&record_path, &record.to_bytes())?;
    let mut info = PairableHostInfo::generate("SoloUse", "Mac17,7");
    info.identifier = record.identifier.clone();
    info.udid = record.identifier.clone();
    let host_key = c.directory.join("host-identity.bin");
    if host_key.exists() {
        info.alt_irk = std::fs::read(&host_key)
            .map_err(|e| e.to_string())?
            .try_into()
            .map_err(|_| "Invalid persisted host identity")?;
    } else {
        private_write(&host_key, &info.alt_irk)?;
    }
    let listener = bounded("pair_listener", 10, TcpListener::bind("0.0.0.0:0")).await?;
    event(
        "advertise",
        json!({"port": listener.local_addr().map_err(|e|e.to_string())?.port(),
        "name": record.identifier(), "txt": info.mdns_txt_records(record.identifier())}),
    );
    let (socket, _) = bounded("await_device_pairing", 180, listener.accept()).await?;
    let mut host = PairableHost::new(RpPairingSocket::new_device(socket), info);
    bounded(
        "pair_handshake",
        120,
        host.accept(&mut record, |pin| async move {
            // PIN events are displayed locally and excluded from diagnostic exports.
            event("pin", json!({"pin": pin}));
        }),
    )
    .await?;
    private_write(&record_path, &record.to_bytes())?;
    event("paired", json!({}));
    Ok(())
}

async fn connect(c: &Config) -> Result<(AdapterHandle, RsdHandshake), String> {
    let ip: IpAddr = c.host.parse().map_err(|_| "Invalid local address")?;
    connect_at(c, SocketAddr::new(ip, c.port)).await
}

fn protocol_error(error: idevice::IdeviceError) -> String {
    match error {
        idevice::IdeviceError::Socket(e) => {
            format!("socket {:?}, errno {:?}", e.kind(), e.raw_os_error())
        }
        other => other.to_string(),
    }
}

async fn connect_at(
    c: &Config,
    endpoint: SocketAddr,
) -> Result<(AdapterHandle, RsdHandshake), String> {
    let data =
        std::fs::read(c.directory.join("pairing.plist")).map_err(|_| "Pair this iPhone first")?;
    let mut record = RpPairingFile::from_bytes(&data).map_err(|_| "Invalid pairing record")?;
    if record.alt_irk.is_none() {
        return Err("Pairing has not completed".into());
    }
    let socket = bounded("local_tcp", 6, TcpStream::connect(endpoint)).await?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(socket), "SoloUse");
    bounded("pair_verify_handshake", 10, async {
        rpc.attempt_pair_verify().await.map_err(protocol_error)
    })
    .await?;
    // Reconnect never silently falls back to a new pairing or rotates identity.
    bounded("pair_verify", 10, async {
        rpc.validate_pairing(&mut record)
            .await
            .map_err(protocol_error)
    })
    .await?;
    let port = bounded("create_listener", 10, rpc.create_tcp_listener()).await?;
    let mut tunnel_endpoint = endpoint;
    tunnel_endpoint.set_port(port);
    let socket = bounded("tunnel_tcp", 8, TcpStream::connect(tunnel_endpoint)).await?;
    let tunnel = bounded(
        "tls_psk_cdtunnel",
        15,
        connect_tls_psk_tunnel_native(socket, rpc.encryption_key()),
    )
    .await?;
    let local = tunnel
        .info
        .client_address
        .parse()
        .map_err(|_| "Bad client address")?;
    let peer = tunnel
        .info
        .server_address
        .parse()
        .map_err(|_| "Bad device address")?;
    let rsd_port = tunnel.info.server_rsd_port;
    let mtu = tunnel.info.mtu as usize;
    let mut adapter =
        idevice::tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), local, peer);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut handle = adapter.to_async_handle();
    let socket = bounded("rsd_tcp", 15, handle.connect(rsd_port)).await?;
    let rsd = bounded("rsd_handshake", 15, RsdHandshake::new(socket)).await?;
    let mut services: Vec<_> = rsd
        .services
        .keys()
        .filter(|s| s.starts_with("com.apple.coredevice"))
        .cloned()
        .collect();
    services.sort();
    event(
        "rsd",
        json!({"service_count": rsd.services.len(), "coredevice_services": services}),
    );
    Ok((handle, rsd))
}

fn wifi_candidate(name: &str, flags: u32, addr: SocketAddr) -> bool {
    name == "en0"
        && flags & libc::IFF_UP as u32 != 0
        && !addr.ip().is_unspecified()
        && !addr.ip().is_loopback()
        && !addr.ip().is_multicast()
}

// Only addresses assigned to this process's device interfaces are returned.
// There is no address or port range scan, DNS lookup, or user-provided target.
fn own_endpoints() -> Result<(Vec<(String, SocketAddr)>, bool), String> {
    let mut result = vec![
        (
            "ipv4_loopback".into(),
            SocketAddr::from(([127, 0, 0, 1], 49152)),
        ),
        (
            "ipv6_loopback".into(),
            SocketAddr::from((Ipv6Addr::LOCALHOST, 49152)),
        ),
    ];
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return Err("Unable to enumerate own interfaces".into());
    }
    struct Guard(*mut libc::ifaddrs);
    impl Drop for Guard {
        fn drop(&mut self) {
            unsafe { libc::freeifaddrs(self.0) }
        }
    }
    let _guard = Guard(head);
    let mut cursor = head;
    let mut local_vpn = false;
    let mut v6_count = 0;
    let mut v4_count = 0;
    while !cursor.is_null() {
        let interface = unsafe { &*cursor };
        cursor = interface.ifa_next;
        if interface.ifa_addr.is_null() || interface.ifa_name.is_null() {
            continue;
        }
        let name = unsafe { CStr::from_ptr(interface.ifa_name) }.to_string_lossy();
        let family = unsafe { (*interface.ifa_addr).sa_family } as i32;
        let addr = match family {
            libc::AF_INET => {
                let raw = unsafe { &*(interface.ifa_addr as *const libc::sockaddr_in) };
                let ip = Ipv4Addr::from(raw.sin_addr.s_addr.to_ne_bytes());
                if name.starts_with("utun")
                    && [Ipv4Addr::new(10, 7, 0, 0), Ipv4Addr::new(10, 7, 1, 1)].contains(&ip)
                    && interface.ifa_flags & libc::IFF_UP as u32 != 0
                {
                    local_vpn = true;
                }
                SocketAddr::from((ip, 49152))
            }
            libc::AF_INET6 => {
                let raw = unsafe { &*(interface.ifa_addr as *const libc::sockaddr_in6) };
                let ip = Ipv6Addr::from(raw.sin6_addr.s6_addr);
                let scope = if ip.is_unicast_link_local() {
                    unsafe { libc::if_nametoindex(interface.ifa_name) }
                } else {
                    raw.sin6_scope_id
                };
                SocketAddr::V6(SocketAddrV6::new(ip, 49152, 0, scope))
            }
            _ => continue,
        };
        if !wifi_candidate(&name, interface.ifa_flags, addr)
            || result.iter().any(|(_, a)| *a == addr)
        {
            continue;
        }
        let label = if addr.is_ipv4() {
            if v4_count >= 1 {
                continue;
            }
            v4_count += 1;
            "wifi_own_ipv4".into()
        } else {
            if v6_count >= 2 {
                continue;
            }
            v6_count += 1;
            format!("wifi_own_ipv6_{v6_count}")
        };
        result.push((label, addr));
    }
    Ok((result, local_vpn))
}

async fn direct_probe(c: &Config) -> Result<(), String> {
    let (endpoints, local_vpn) = own_endpoints()?;
    event(
        "direct_environment",
        json!({"default_localdevvpn_interface_present":local_vpn,
        "candidate_labels":endpoints.iter().map(|(label,_)|label).collect::<Vec<_>>()}),
    );
    if local_vpn {
        return Err(
            "LocalDevVPN interface is still active; disconnect it for this experiment".into(),
        );
    }
    let mut successful = 0;
    for (label, endpoint) in endpoints {
        if CANCEL.load(Ordering::Acquire) {
            return Err("Cancelled".into());
        }
        let started = Instant::now();
        event("direct_candidate", json!({"candidate":label}));
        let result = match connect_at(c, endpoint).await {
            Ok((mut a, mut r)) => {
                let capture = screenshot(c, &mut a, &mut r, "direct.png").await;
                let _ = tokio::time::timeout(Duration::from_secs(3), a.close()).await;
                capture
            }
            Err(e) => Err(e),
        };
        match result {
            Ok(()) => {
                successful += 1;
                event(
                    "direct_result",
                    json!({"candidate":label,"ok":true,"elapsed_ms":started.elapsed().as_millis() as u64}),
                );
            }
            Err(e) => event(
                "direct_result",
                json!({"candidate":label,"ok":false,"message":e,"elapsed_ms":started.elapsed().as_millis() as u64}),
            ),
        }
    }
    event("direct_summary", json!({"successful_routes":successful}));
    if successful == 0 {
        Err("No tested VPN-free self route completed RSD and screenshot".into())
    } else {
        Ok(())
    }
}

async fn screenshot(
    c: &Config,
    a: &mut AdapterHandle,
    r: &mut RsdHandshake,
    name: &str,
) -> Result<(), String> {
    let mut client = bounded(
        "screenshot_service",
        15,
        ScreenCaptureServiceClient::connect_rsd(a, r),
    )
    .await?;
    let png = bounded(
        "screenshot_capture",
        15,
        client.take_screenshot(None, ImageFormat::Png),
    )
    .await?;
    if png.len() < 24 || &png[..8] != b"\x89PNG\r\n\x1a\n" {
        return Err("Invalid screenshot PNG".into());
    }
    private_write(&c.directory.join(name), &png)?;
    event("screenshot", json!({"file": name, "bytes": png.len()}));
    Ok(())
}

async fn probe(c: &Config) -> Result<(), String> {
    let (mut adapter, mut rsd) = connect(c).await?;
    let result = async {
        screenshot(c, &mut adapter, &mut rsd, "before.png").await?;
        if c.mode != "probe" {
            control(c, &mut adapter, &mut rsd).await?;
        }
        Ok(())
    }
    .await;
    let _ = tokio::time::timeout(Duration::from_secs(5), adapter.close()).await;
    result
}

// Hardware diagnostics use the same media transport but have no model workflow.
async fn control(c: &Config, a: &mut AdapterHandle, r: &mut RsdHandshake) -> Result<(), String> {
    let media = media::MediaSession::open(a, r, &c.directory).await?;
    let result=async {
        let mut hid=bounded("hid_service",12,UniversalHidServiceClient::connect_rsd(a,r)).await?;
        let mut buttons=bounded("button_service",12,IndigoHidClient::connect_rsd(a,r)).await?;
        tokio::time::sleep(Duration::from_secs(3)).await;
        if CANCEL.load(Ordering::Acquire){return Err("Cancelled".into())}
        if c.mode=="touch" {
            bounded("send_test_tap",5,hid.tap(normalized(c.x)?,normalized(c.y)?)).await?;
            event("action_sent",json!({"action":"tap_test_target","verified":false}));
            tokio::time::sleep(Duration::from_secs(3)).await;
        } else {
            bounded("home_down",5,buttons.send_button(0x0c,0x40,ButtonState::Down)).await?;
            tokio::time::sleep(Duration::from_millis(60)).await;
            bounded("home_up",5,buttons.send_button(0x0c,0x40,ButtonState::Up)).await?;
            event("action_sent",json!({"action":"home","verified":false}));
            let start=Instant::now();let mut next_checkpoint=60;
            while start.elapsed().as_secs()<c.background_seconds {
                if CANCEL.load(Ordering::Acquire){return Err("Cancelled".into())}
                if let Some(error)=media.failure(){return Err(error)}
                let elapsed=start.elapsed().as_secs();
                if elapsed>=next_checkpoint {
                    screenshot(c,a,r,"background-checkpoint.png").await?;
                    event("background_checkpoint",json!({"elapsed_seconds":elapsed,"rtp_packets":media.packets.load(Ordering::Relaxed)}));
                    next_checkpoint+=60;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            event("background_watch_completed",json!({"elapsed_ms":start.elapsed().as_millis() as u64,"rtp_packets":media.packets.load(Ordering::Relaxed)}));
        }
        screenshot(c,a,r,"after.png").await
    }.await;
    media.close().await;
    result
}

fn find_key<'a>(v: &'a plist::Value, key: &str) -> Option<&'a plist::Value> {
    match v {
        plist::Value::Dictionary(d) => d
            .get(key)
            .or_else(|| d.values().find_map(|v| find_key(v, key))),
        plist::Value::Array(a) => a.iter().find_map(|v| find_key(v, key)),
        _ => None,
    }
}
fn normalized(v: f64) -> Result<u16, String> {
    if !v.is_finite() || !(0.0..=1.0).contains(&v) {
        return Err("Invalid normalized coordinate".into());
    }
    Ok((v * 65535.0).round() as u16)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn signing_prefix_is_configurable_and_rejects_paths() {
        let mut c: Config = serde_json::from_value(json!({"mode":"probe","directory":"/tmp/solouse","bundle_prefix":"org.example.preview"})).unwrap();
        assert_eq!(c.bundle_prefix, "org.example.preview");
        assert!(validate(&c).is_ok());
        for invalid in ["", "../escape", "prefix..bad", ".prefix", "prefix.", "prefix/child"] {
            c.bundle_prefix = invalid.into(); assert!(validate(&c).is_err());
        }
        let defaults: Config = serde_json::from_value(json!({"mode":"probe","directory":"/tmp/solouse"})).unwrap();
        assert_eq!(defaults.bundle_prefix, "dev.solouse");
    }
    #[test]
    fn accepts_discovered_local_port_with_legacy_default() {
        let mut c: Config = serde_json::from_value(json!({"mode":"probe","directory":"/tmp/solouse"})).unwrap();
        assert_eq!(c.port, 49152);
        c.port = 65139;
        assert!(validate(&c).is_ok());
        c.port = 0;
        assert!(validate(&c).is_err());
        assert!(serde_json::from_value::<Config>(json!({"mode":"probe","directory":"/tmp/solouse","port":65536})).is_err());
    }
    #[test]
    fn rejects_remote_addresses_and_bad_touch_targets() {
        let mut c = Config {
            mode: "touch".into(),
            directory: "/tmp/solouse".into(),
            host: default_host(),
            port: default_port(),
            x: 0.5,
            y: 0.5,
            background_seconds: 300,
            session_id: None,
            bundle_prefix: default_bundle_prefix(),
            read_only: true,
            keyboard_tuning: KeyboardTuning::default(),
        };
        assert!(validate(&c).is_ok());
        c.host = "8.8.8.8".into();
        assert!(validate(&c).is_err());
        c.host = default_host();
        c.y = f64::NAN;
        assert!(validate(&c).is_err());
        c.y = 1.0;
        assert!(validate(&c).is_err());
    }
    #[test]
    fn background_duration_is_bounded_and_defaults_to_five_minutes() {
        let mut c: Config =
            serde_json::from_value(json!({"mode":"background","directory":"/tmp/solouse"}))
                .unwrap();
        assert_eq!(c.background_seconds, 300);
        for seconds in [60, 300, 600, 1800] {
            c.background_seconds = seconds;
            assert!(validate(&c).is_ok());
        }
        for seconds in [0, 35, 1801, u64::MAX] {
            c.background_seconds = seconds;
            assert!(validate(&c).is_err());
        }
    }
    #[test]
    fn maps_touch_coordinates_without_wrapping() {
        assert_eq!(normalized(0.5).unwrap(), 32768);
        assert_eq!(normalized(1.0).unwrap(), 65535);
        assert!(normalized(-0.1).is_err());
        assert!(normalized(f64::INFINITY).is_err());
    }
    #[test]
    fn direct_probe_accepts_only_own_wifi_interface_candidates() {
        let own: SocketAddr = "192.168.10.4:49152".parse().unwrap();
        assert!(wifi_candidate("en0", libc::IFF_UP as u32, own));
        assert!(!wifi_candidate("utun0", libc::IFF_UP as u32, own));
        assert!(!wifi_candidate("pdp_ip0", libc::IFF_UP as u32, own));
        assert!(!wifi_candidate("en0", 0, own));
        assert!(!wifi_candidate(
            "en0",
            libc::IFF_UP as u32,
            "224.0.0.1:49152".parse().unwrap()
        ));
    }
}
