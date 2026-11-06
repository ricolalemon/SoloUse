use super::*;
use std::sync::atomic::AtomicU64;

pub(super) struct MediaSession {
    display: DisplayServiceClient<Box<dyn idevice::ReadWrite>>,
    pump: tokio::task::JoinHandle<()>,
    pub packets: std::sync::Arc<AtomicU64>,
    failure: std::sync::Arc<Mutex<Option<String>>>,
    lease: MediaLease,
}

impl MediaSession {
    pub(super) async fn open(a: &mut AdapterHandle, r: &mut RsdHandshake, directory: &std::path::Path) -> Result<Self, String> {
        let mut display = bounded(
            "display_service",
            12,
            DisplayServiceClient::connect_rsd(a, r),
        )
        .await?;
        let status = bounded(
            "display_status",
            8,
            display.get_media_stream_server_status(),
        )
        .await?;
        let owners = stream_owners(&status).ok_or("An existing display session is active")?;
        let lease_path = directory.join("media-session-owner");
        if !owners.is_empty() {
            let previous = MediaLease::load(lease_path.clone())
                .filter(|lease| owners.iter().all(|id| *id == lease.id))
                .ok_or("An existing display session is active")?;
            // RUNNING serializes all native workers. A persisted UUID belongs to
            // our previous session; never stop a foreign or unidentifiable stream.
            bounded("recover_previous_display", 12, stop_owned(&mut display, &previous)).await?;
            event("media_recovered", json!({"stream_count": owners.len()}));
        }
        let audio = bounded("audio_socket", 5, a.bind_udp(0)).await?;
        let video = bounded("video_socket", 5, a.bind_udp(0)).await?;
        let info = CallInfoBlob {
            call_id: 0,
            client_version: 1,
            device_type: "Mac17,7".into(),
            framework_version: "2205.3.1".into(),
            os_version: "25F71".into(),
            device_name: None,
            audio_device_uid: None,
        };
        let session = uuid::Uuid::new_v4();
        let lease = MediaLease { path: lease_path, id: session };
        // Persist before any start request: a killed process cannot clean up,
        // and a timed-out start may still have succeeded on iOS.
        private_write(&lease.path, session.to_string().as_bytes())?;
        let audio_id = uuid::Uuid::new_v4().to_string().to_uppercase();
        let video_id = uuid::Uuid::new_v4().to_string().to_uppercase();
        let ssrc = (uuid::Uuid::new_v4().as_u128() as u32).max(1);
        let local = a.host_ip().to_string();
        let peer = a.peer_ip().to_string();
        let offer = build_screen_audio_offer(&audio_id, &info).map_err(|e| e.to_string())?;
        let audio_started = bounded(
            "start_audio",
            15,
            display.start_media_stream(build_start_audio_parameters(
                &local,
                audio.local_port(),
                &peer,
                50000,
                offer,
                140,
                session,
            )),
        )
        .await;
        if let Err(error) = audio_started {
            let _ = stop_owned(&mut display, &lease).await;
            return Err(error);
        }
        let started = async {
            let offer =
                build_screen_video_offer(&video_id, &info, ssrc).map_err(|e| e.to_string())?;
            bounded(
                "start_video",
                15,
                display.start_media_stream(build_start_video_parameters(
                    &local,
                    video.local_port(),
                    &peer,
                    50001,
                    offer,
                    140,
                    1,
                    session,
                )),
            )
            .await
        }
        .await;
        if let Err(error) = started {
            let _ = stop_owned(&mut display, &lease).await;
            return Err(error);
        }
        let packets = std::sync::Arc::new(AtomicU64::new(0));
        let packet_count = packets.clone();
        let failure = std::sync::Arc::new(Mutex::new(None));
        let error_slot = failure.clone();
        let pump = tokio::spawn(async move {
            let started = Instant::now();
            let mut last_packet = started;
            let mut stats = tokio::time::interval(Duration::from_secs(1));
            let mut feedback = tokio::time::interval(Duration::from_millis(100));
            let (mut frames, mut highest) = (0u16, 0u16);
            loop {
                tokio::select! {
                    _=cancellation()=>break,
                    packet=video.recv()=>match packet {
                        Ok(d)=>if !is_rtcp(&d.data) {if let Some(p)=RtpPacket::parse(&d.data) {
                            packet_count.fetch_add(1,Ordering::Relaxed);highest=p.sequence_number;last_packet=Instant::now();
                            if p.marker {frames=frames.wrapping_add(1);let _=video.send_to(50001,build_frame_ack(ssrc,p.timestamp)).await;}
                        }},
                        Err(_)=>{*error_slot.lock().unwrap()=Some("Display stream disconnected".into());break;}
                    },
                    _=audio.recv()=>{},
                    _=feedback.tick()=>{let _=video.send_to(50001,build_rctl(ssrc,started.elapsed().as_millis() as u16,frames,highest)).await;},
                    _=stats.tick()=>{
                        let seconds=started.elapsed().as_secs();
                        event("stream",json!({"seconds":seconds,"rtp_packets":packet_count.load(Ordering::Relaxed),"last_packet_age_ms":last_packet.elapsed().as_millis() as u64}));
                        let _=video.send_to(50001,build_liveness(ssrc,&video_id,&[])).await;
                        if last_packet.elapsed()>Duration::from_secs(30){*error_slot.lock().unwrap()=Some("Display stream stalled".into());break;}
                    }
                }
            }
        });
        let media = Self {
            display,
            pump,
            packets,
            failure,
            lease,
        };
        let ready = bounded("display_ready", 12, async {
            while media.packets.load(Ordering::Relaxed) == 0 {
                if let Some(error) = media.failure() {
                    return Err(error);
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
            Ok::<(), String>(())
        })
        .await;
        if let Err(error) = ready {
            media.close().await;
            return Err(error);
        }
        Ok(media)
    }
    pub(super) fn failure(&self) -> Option<String> {
        self.failure.lock().unwrap().clone()
    }
    pub(super) async fn close(mut self) {
        if stop_owned(&mut self.display, &self.lease).await.is_err() {
            event("media_cleanup_deferred", json!({"reason": "Ownership or shutdown could not be confirmed; retained local session marker"}));
        }
        self.pump.abort();
        let _ = self.pump.await;
    }
}


struct MediaLease {
    path: PathBuf,
    id: uuid::Uuid,
}
impl MediaLease {
    fn load(path: PathBuf) -> Option<Self> {
        if std::fs::metadata(&path).ok()?.len() > 64 { return None; }
        let id = uuid::Uuid::parse_str(std::fs::read_to_string(&path).ok()?.trim()).ok()?;
        Some(Self { path, id })
    }
    fn clear(&self) -> Result<(), String> {
        // An older close must never remove a newer session's marker.
        if Self::load(self.path.clone()).is_some_and(|value| value.id == self.id) {
            std::fs::remove_file(&self.path).map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

// None means ownership cannot be established. Empty is a confirmed idle server.
fn stream_owners(status: &plist::Value) -> Option<Vec<uuid::Uuid>> {
    let running = find_key(status, "running").and_then(plist::Value::as_boolean);
    let sessions = find_key(status, "sessions").and_then(plist::Value::as_array)?;
    if sessions.is_empty() {
        return (running == Some(false)).then(Vec::new);
    }
    sessions.iter().map(|session| {
        let option = find_key(session, "avcMediaStreamOptionClientSessionID")?;
        let value = find_key(option, "uuid")?.as_string()?;
        uuid::Uuid::parse_str(value).ok()
    }).collect()
}

async fn stop_owned(
    display: &mut DisplayServiceClient<Box<dyn idevice::ReadWrite>>,
    lease: &MediaLease,
) -> Result<(), String> {
    let status = tokio::time::timeout(Duration::from_secs(4), display.get_media_stream_server_status())
        .await.map_err(|_| "Display status timed out")?.map_err(|e| e.to_string())?;
    let owners = stream_owners(&status).ok_or("Display ownership is unknown")?;
    if !owners.is_empty() {
        if !owners.iter().all(|id| *id == lease.id) { return Err("A different display session is active".into()); }
        tokio::time::timeout(Duration::from_secs(4), display.stop_media_stream())
            .await.map_err(|_| "Display stop timed out")?.map_err(|e| e.to_string())?;
        let after = tokio::time::timeout(Duration::from_secs(4), display.get_media_stream_server_status())
            .await.map_err(|_| "Display stop verification timed out")?.map_err(|e| e.to_string())?;
        if stream_owners(&after) != Some(vec![]) { return Err("Display stop could not be verified".into()); }
    }
    lease.clear()
}

#[cfg(test)]
mod recovery_tests {
    use super::*;
    fn status(ids: &[&str], running: bool) -> plist::Value {
        let mut root = plist::Dictionary::new();
        root.insert("running".into(), plist::Value::Boolean(running));
        root.insert("sessions".into(), plist::Value::Array(ids.iter().map(|id| {
            let mut value = plist::Dictionary::new(); value.insert("uuid".into(), (*id).into());
            let mut options = plist::Dictionary::new(); options.insert("avcMediaStreamOptionClientSessionID".into(), value.into());
            plist::Value::Dictionary(options)
        }).collect()));
        root.into()
    }
    #[test]
    fn status_requires_known_owners_and_confirmed_idle() {
        let a = uuid::Uuid::new_v4().to_string(); let b = uuid::Uuid::new_v4().to_string();
        assert_eq!(stream_owners(&status(&[], false)), Some(vec![]));
        assert_eq!(stream_owners(&status(&[], true)), None);
        assert_eq!(stream_owners(&status(&["invalid"], true)), None);
        let own = stream_owners(&status(&[&a, &a], true)).unwrap();
        assert!(own.iter().all(|id| id.to_string() == a));
        let mixed = stream_owners(&status(&[&a, &b], true)).unwrap();
        assert!(!mixed.iter().all(|id| id.to_string() == a));
        assert_eq!(stream_owners(&plist::Value::Dictionary(plist::Dictionary::new())), None);
    }
    #[test]
    fn durable_marker_roundtrip_does_not_clear_newer_owner() {
        let root = std::env::temp_dir().join(format!("solouse-media-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let old = MediaLease {path: root.join("media-session-owner"), id: uuid::Uuid::new_v4()};
        private_write(&old.path, old.id.to_string().as_bytes()).unwrap();
        assert_eq!(MediaLease::load(old.path.clone()).unwrap().id, old.id);
        let new = MediaLease {path: old.path.clone(), id: uuid::Uuid::new_v4()};
        private_write(&new.path, new.id.to_string().as_bytes()).unwrap();
        old.clear().unwrap(); assert!(new.path.exists());
        new.clear().unwrap(); assert!(!new.path.exists());
        std::fs::remove_dir_all(root).unwrap();
    }
}
