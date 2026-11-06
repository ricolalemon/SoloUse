//! Local-device clipboard transport based on idevice's MIT-licensed
//! core_device/pasteboard_service.rs at the pinned dependency revision.
//! Clipboard contents never enter model responses or diagnostic events.
use super::*;
use idevice::core_device::{
    PasteboardEntry, PasteboardItem, PasteboardPayload, PasteboardSnapshot,
};
use idevice::{
    ReadWrite, RemoteXpcClient, xpc,
    xpc::{Dictionary, XPCObject},
};

pub(super) struct ClipboardLease<C = ClipboardClient> {
    client: C,
    original: PasteboardSnapshot,
    owned_count: Option<i64>,
    pub id: String,
    text_hash: Option<[u8; 32]>,
    pub changed: bool,
}
pub(super) struct ClipboardClient {
    inner: RemoteXpcClient<Box<dyn ReadWrite>>,
}
pub(super) trait ClipboardTransport {
    async fn snapshot(&mut self) -> Result<PasteboardSnapshot, String>;
    async fn change_count(&mut self) -> Result<Option<i64>, String>;
    async fn set_items(&mut self, items: Vec<XPCObject>) -> Result<(), String>;
}
impl ClipboardTransport for ClipboardClient {
    async fn snapshot(&mut self) -> Result<PasteboardSnapshot, String> { self.get().await }
    async fn change_count(&mut self) -> Result<Option<i64>, String> {
        Ok(self.get_policy("all_promised").await?.change_count)
    }
    async fn set_items(&mut self, items: Vec<XPCObject>) -> Result<(), String> { self.set(items).await }
}
impl RsdService for ClipboardClient {
    fn rsd_service_name() -> std::borrow::Cow<'static, str> {
        "com.apple.coredevice.pasteboardservice".into()
    }
    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, idevice::IdeviceError> {
        let mut inner = RemoteXpcClient::new(stream).await?;
        inner.do_handshake().await?;
        Ok(Self { inner })
    }
}
impl ClipboardClient {
    async fn resolve(&mut self, index: usize, uti: &str) -> Result<Vec<u8>, String> {
        self.inner.send_object(xpc!({"command":"RESOLVE", "pasteboardName":"general",
            "itemIndex": index as i64, "type": uti}), true).await.map_err(|_|"Clipboard resolve request failed")?;
        let reply=self.inner.recv().await.map_err(|_|"Clipboard resolve response failed")?;
        reply.as_dictionary().and_then(|d|d.get("data")).and_then(|d|d.as_data())
            .map(|data|data.to_vec()).ok_or_else(||"Clipboard representation could not be resolved".into())
    }
    async fn get(&mut self) -> Result<PasteboardSnapshot, String> {
        // Metadata can remain readable when an item's provider cannot deliver
        // its bytes. Keep the phone command loop available for permission UI.
        tokio::time::timeout(Duration::from_secs(2), self.get_policy("threshold"))
            .await.map_err(|_| "Clipboard payload unavailable; foreground preparation required".to_string())?
    }
    async fn get_policy(&mut self, policy: &str) -> Result<PasteboardSnapshot, String> {
        let data_policy = match policy {
            "all_promised" => xpc!({"allPromised": XPCObject::Dictionary(Dictionary::new())}),
            "all_resolved" => xpc!({"allResolved": XPCObject::Dictionary(Dictionary::new())}),
            "match_source" => xpc!({"matchSource": XPCObject::Dictionary(Dictionary::new())}),
            "threshold" => xpc!({"thresholdData": {"bytes": 1000000i64}}),
            _ => return Err("Invalid clipboard read policy".into()),
        };
        let message = xpc!({"command":"PULL", "pasteboardName":"general",
            "dataPolicy": data_policy});
        self.inner
            .send_object(message, true)
            .await
            .map_err(|_| "Clipboard request failed")?;
        let reply = self
            .inner
            .recv()
            .await
            .map_err(|_| "Clipboard response failed")?;
        let parsed = parse_snapshot(&reply);
        if parsed.is_err() {
            let root = reply.as_dictionary();
            let body = root.and_then(|d| d.get("pasteboard")).and_then(|v| v.as_dictionary());
            // Schema only: no clipboard contents, text, bytes or source metadata.
            event("clipboard_reply_shape",json!({
                "root_keys":root.map(|d|d.keys().take(16).cloned().collect::<Vec<_>>()),
                "body_keys":body.map(|d|d.keys().take(16).cloned().collect::<Vec<_>>()),
                "command":root.and_then(|d|d.get("command")).and_then(|v|v.as_string()).filter(|s|["PULL_REPLY","PUSH","ERROR","SET_REPLY"].contains(s)),
                "items_count":body.and_then(|d|d.get("items")).and_then(|v|v.as_array()).map(Vec::len),
                "error_keys":root.and_then(|d|d.get("error")).and_then(|v|v.as_dictionary()).map(|d|d.keys().take(16).cloned().collect::<Vec<_>>()),
                "error_code":root.and_then(|d|d.get("error")).and_then(|v|v.as_dictionary()).and_then(|d|d.get("code")).and_then(|v|v.as_signed_integer()),
                "error_domain":root.and_then(|d|d.get("error")).and_then(|v|v.as_dictionary()).and_then(|d|d.get("domain")).and_then(|v|v.as_string()).filter(|s|s.len()<200 && s.bytes().all(|b|b.is_ascii_alphanumeric() || b"._-".contains(&b))),
                "error_description":root.and_then(|d|d.get("error")).and_then(|v|v.as_dictionary()).and_then(|d|d.get("userInfo")).and_then(|v|v.as_dictionary()).and_then(|d|d.get("NSLocalizedDescription")).and_then(|v|v.as_string()).map(|s|s.chars().take(400).collect::<String>()),
                "error_reason":root.and_then(|d|d.get("error")).and_then(|v|v.as_dictionary()).and_then(|d|d.get("userInfo")).and_then(|v|v.as_dictionary()).and_then(|d|d.get("NSLocalizedFailureReason")).and_then(|v|v.as_string()).map(|s|s.chars().take(400).collect::<String>()),
            }));
        }
        parsed
    }
    async fn set(&mut self, items: Vec<XPCObject>) -> Result<(), String> {
        self.inner
            .send_object(
                xpc!({"command":"SET", "pasteboardName":"general",
            "items": XPCObject::Array(items), "sourceMetadata": XPCObject::Null}),
                true,
            )
            .await
            .map_err(|_| "Clipboard update failed")?;
        let reply = self.inner
            .recv()
            .await
            .map_err(|_| "Clipboard update acknowledgement failed")?;
        if reply.as_dictionary().is_none_or(|d| d.contains_key("error")) {
            return Err("Clipboard service rejected the update".into());
        }
        Ok(())
    }
}
pub(super) async fn status(a: &mut AdapterHandle, r: &mut RsdHandshake) -> Result<Value, String> {
    let mut client=ClipboardClient::connect_rsd(a,r).await.map_err(|_|"Clipboard status unavailable")?;
    // A format list is not a usable backup. Validate the actual representations
    // before leaving SoloUse, where UIKit can resolve an authorized local copy.
    // Payloads stay on-device and never appear in the status reply or logs.
    match client.get().await.and_then(|snapshot| encoded_items(&snapshot).map(|_| ())) {
        Ok(_)=>Ok(json!({"requires_local_copy":false,"payload_readable":true})),
        Err(error) if needs_local_preparation(&error)=>Ok(json!({"requires_local_copy":true,"payload_readable":false})),
        Err(error)=>Err(error),
    }
}
pub(super) fn needs_local_preparation(error: &str) -> bool {
    error.contains("Remote-origin clipboard requires local preparation")
        || error.contains("Clipboard payload unavailable; foreground preparation required")
        || error.contains("Clipboard has unresolved or large content")
}
pub(super) async fn probe(a: &mut AdapterHandle, r: &mut RsdHandshake, policy: &str) -> Result<Value, String> {
    let started = Instant::now();
    let mut client = ClipboardClient::connect_rsd(a, r).await.map_err(|e|e.to_string())?;
    let snapshot = client.get_policy(if policy=="resolve" {"all_promised"} else {policy}).await?;
    let mut resolved = Vec::new();
    if policy=="resolve" {
        for item in &snapshot.items {
            for entry in &item.data {
                // Independent connections isolate a stalled representation; no
                // contents are exposed by this development-only probe.
                let result=tokio::time::timeout(Duration::from_secs(6),async {
                    let mut resolver=ClipboardClient::connect_rsd(a,r).await.map_err(|e|e.to_string())?;
                    let current=resolver.get_policy("all_promised").await?;
                    if current.change_count!=snapshot.change_count {return Err("Clipboard changed".to_string());}
                    resolver.resolve(item.index,&entry.uti).await.map(|data|data.len())
                }).await;
                resolved.push(match result {
                    Ok(Ok(bytes))=>json!({"format":entry.uti,"bytes":bytes,"status":"resolved"}),
                    Ok(Err(error))=>json!({"format":entry.uti,"status":"failed","error":error}),
                    Err(_)=>json!({"format":entry.uti,"status":"timeout"}),
                });
            }
        }
    }
    let entries = snapshot.items.iter().flat_map(|item| item.data.iter());
    let (mut inline, mut promised, mut bytes) = (0, 0, 0);
    for entry in entries {
        match &entry.payload {
            PasteboardPayload::Inline(data) => {inline += 1;bytes += data.len();},
            _ => promised += 1,
        }
    }
    Ok(json!({"policy":policy,"elapsed_ms":started.elapsed().as_millis() as u64,
        "items":snapshot.items.len(),"inline_entries":inline,"promised_entries":promised,
        "inline_bytes":bytes,"has_change_count":snapshot.change_count.is_some(),
        "formats":snapshot.items.iter().map(|item|&item.types).collect::<Vec<_>>(),"resolved":resolved}))
}
fn parse_snapshot(value: &plist::Value) -> Result<PasteboardSnapshot, String> {
    let root = value.as_dictionary().ok_or("Invalid clipboard object")?;
    if root.contains_key("error") {
        if root.get("error").and_then(|v|v.as_dictionary())
            .filter(|d|d.get("domain").and_then(|v|v.as_string())==Some("com.apple.dt.CoreDeviceError")
                && d.get("code").and_then(|v|v.as_signed_integer())==Some(26006))
            .and_then(|d|d.get("userInfo")).and_then(|v|v.as_dictionary())
            .and_then(|d|d.get("NSLocalizedDescription")).and_then(|v|v.as_string())
            .is_some_and(|text|text.contains("com.apple.is-remote-clipboard")) {
            return Err("Remote-origin clipboard requires local preparation in SoloUse".into());
        }
        return Err("Clipboard service rejected the read; original clipboard was not changed".into());
    }
    let body = root
        .get("pasteboard")
        .and_then(|v| v.as_dictionary())
        .unwrap_or(root);
    let metadata = body
        .get("metadata")
        .and_then(|v| v.as_dictionary())
        .ok_or("Clipboard metadata missing")?;
    let change_count = metadata
        .get("changeCount")
        .and_then(|v| v.as_signed_integer());
    let mut items = Vec::new();
    {
        let raw = body.get("items").ok_or("Clipboard items missing")?;
        let raw = raw.as_array().ok_or("Invalid clipboard items")?;
        if raw.len() > 64 {
            return Err("Clipboard has too many items".into());
        }
        for (index, item) in raw.iter().enumerate() {
            let item = item.as_dictionary().ok_or("Invalid clipboard item")?;
            let types = item
                .get("types")
                .and_then(|v| v.as_array())
                .ok_or("Clipboard types missing")?
                .iter()
                .map(|v| {
                    v.as_string()
                        .map(str::to_owned)
                        .ok_or("Invalid clipboard type".to_owned())
                })
                .collect::<Result<Vec<_>, _>>()?;
            let raw = item
                .get("data")
                .and_then(|v| v.as_dictionary())
                .ok_or("Clipboard item data missing")?;
            let data = raw
                .iter()
                .map(|(uti, value)| {
                    let bytes = value
                        .as_dictionary()
                        .and_then(|v| v.get("data"))
                        .and_then(|v| v.as_data());
                    PasteboardEntry {
                        uti: uti.clone(),
                        payload: bytes
                            .map(|b| PasteboardPayload::Inline(b.to_vec()))
                            .unwrap_or(PasteboardPayload::Promised { size: None }),
                    }
                })
                .collect();
            items.push(PasteboardItem { index, types, data });
        }
    }
    Ok(PasteboardSnapshot {
        pasteboard_name: Some("general".into()),
        change_count,
        items,
    })
}
fn encoded_items(snapshot: &PasteboardSnapshot) -> Result<Vec<XPCObject>, String> {
    if snapshot.items.len() > 64 {
        return Err("Clipboard has too many items to preserve".into());
    }
    let mut total = 0;
    snapshot
        .items
        .iter()
        .map(|item| {
            let mut data = Dictionary::new();
            for entry in &item.data {
                let PasteboardPayload::Inline(bytes) = &entry.payload else {
                    return Err(
                        "Clipboard has unresolved or large content; no paste was performed".into(),
                    );
                };
                total += bytes.len();
                if total > 2_000_000 {
                    return Err("Clipboard is too large to preserve; no paste was performed".into());
                }
                data.insert(entry.uti.clone(), xpc!({"data": bytes.as_slice()}));
            }
            if item.types.iter().any(|uti| !data.contains_key(uti)) {
                return Err("Clipboard format cannot be preserved".into());
            }
            Ok(xpc!({"types": item.types.clone(), "data": XPCObject::Dictionary(data)}))
        })
        .collect()
}
fn text_items(text: &str) -> Vec<XPCObject> {
    let types = vec!["public.utf8-plain-text", "public.plain-text", "public.text"];
    let mut data = Dictionary::new();
    for uti in &types {
        data.insert((*uti).into(), xpc!({"data": text.as_bytes()}));
    }
    vec![xpc!({"types": types, "data": XPCObject::Dictionary(data)})]
}
fn same_contents(a: &PasteboardSnapshot, b: &PasteboardSnapshot) -> bool {
    if a.items.len() != b.items.len() {
        return false;
    }
    a.items.iter().zip(&b.items).all(|(left, right)| {
        left.types == right.types
            && left.data.len() == right.data.len()
            && left.data.iter().all(|entry| {
                right.data.iter().any(|other| {
                    entry.uti == other.uti
                        && match (&entry.payload, &other.payload) {
                            (PasteboardPayload::Inline(x), PasteboardPayload::Inline(y)) => x == y,
                            _ => false,
                        }
                })
            })
    })
}
impl ClipboardLease {
    pub async fn prepare(a: &mut AdapterHandle, r: &mut RsdHandshake) -> Result<Self, String> {
        if !r
            .services
            .contains_key("com.apple.coredevice.pasteboardservice")
        {
            return Err("This phone did not advertise clipboard support".into());
        }
        event("clipboard_stage",json!({"stage":"connect"}));
        let mut client = ClipboardClient::connect_rsd(a, r)
            .await
            .map_err(|_| "Cannot connect to clipboard service")?;
        event("clipboard_stage",json!({"stage":"read_original"}));
        let original = client.get().await?;
        event("clipboard_stage",json!({"stage":"original_read"}));
        encoded_items(&original)?;
        if original.change_count.is_none() {
            return Err("Clipboard change counter unavailable".into());
        }
        Ok(Self {
            client,
            original,
            owned_count: None,
            id: uuid::Uuid::new_v4().to_string(),
            text_hash: None,
            changed: false,
        })
    }
    pub async fn reconnect(&mut self, a: &mut AdapterHandle, r: &mut RsdHandshake) -> Result<(), String> {
        // A lease can span model turns. Never reuse a stale/cancelled exchange.
        self.client=ClipboardClient::connect_rsd(a,r).await.map_err(|_|"Clipboard connection unavailable")?;
        Ok(())
    }
    pub async fn still_owned(&mut self) -> Result<bool, String> {
        match self.client.get_policy("all_promised").await {
            Ok(snapshot)=>Ok(self.owned_count.is_some() && snapshot.change_count==self.owned_count),
            Err(error) if error.contains("Remote-origin clipboard requires local preparation")=>Ok(false),
            Err(error)=>Err(error),
        }
    }
}
impl<C: ClipboardTransport> ClipboardLease<C> {
    pub fn matches_text(&self, text: &str) -> bool {
        use sha2::Digest;
        self.text_hash==Some(sha2::Sha256::digest(text.as_bytes()).into())
    }
    pub async fn write(&mut self, text: &str) -> Result<(), String> {
        // Check for a concurrent copy before replacing the original snapshot.
        if self.client.change_count().await? != self.original.change_count {
            return Err("Clipboard changed before paste; please observe and retry".into());
        }
        self.changed = true;
        self.client.set_items(text_items(text)).await?;
        let own = self.client.snapshot().await?;
        if own.text().as_deref() != Some(text) || own.change_count.is_none() {
            return Err("Clipboard update could not be verified".into());
        }
        self.owned_count = own.change_count;
        use sha2::Digest;
        self.text_hash=Some(sha2::Sha256::digest(text.as_bytes()).into());
        event("clipboard_stage",json!({"stage":"held","paste_id":self.id}));
        Ok(())
    }
    pub async fn restore(&mut self) -> Result<bool, String> {
        if !self.changed {
            return Ok(true);
        }
        let owned = self
            .owned_count
            .ok_or("Clipboard update was uncertain; current clipboard left unchanged")?;
        let current = match self.client.change_count().await {
            Ok(count)=>count,
            // Our staged text has no remote marker: a remote copy is newer user
            // content. Preserve it rather than treating it as an empty board.
            Err(error) if error.contains("Remote-origin clipboard requires local preparation")=>return Ok(false),
            Err(error)=>return Err(error),
        };
        if current != Some(owned) {
            return Ok(false);
        }
        event("clipboard_stage",json!({"stage":"restore_started","paste_id":self.id}));
        self.client.set_items(encoded_items(&self.original)?).await?;
        let restored = self.client.snapshot().await?;
        if !same_contents(&self.original, &restored) {
            return Err("Clipboard restoration could not be verified".into());
        }
        self.changed = false;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use idevice::core_device::{PasteboardEntry, PasteboardItem};
    use std::sync::{Arc,Mutex};

    struct MemoryBoard { snapshot:PasteboardSnapshot,writes:usize,remote:bool,fail_set_ack:bool,fail_payload:bool }
    struct MemoryClient(Arc<Mutex<MemoryBoard>>);
    impl ClipboardTransport for MemoryClient {
        async fn change_count(&mut self)->Result<Option<i64>,String> {
            let board=self.0.lock().unwrap();
            if board.remote {Err("Remote-origin clipboard requires local preparation in SoloUse".into())}
            else {Ok(board.snapshot.change_count)}
        }
        async fn snapshot(&mut self)->Result<PasteboardSnapshot,String> {
            let board=self.0.lock().unwrap();
            if board.fail_payload {return Err("Clipboard payload unavailable; foreground preparation required".into());}
            if board.remote {Err("Remote-origin clipboard requires local preparation in SoloUse".into())}
            else {Ok(board.snapshot.clone())}
        }
        async fn set_items(&mut self,items:Vec<XPCObject>)->Result<(),String> {
            let mut board=self.0.lock().unwrap();
            let next=board.snapshot.change_count.unwrap()+1;
            board.snapshot=parse_snapshot(&xpc!({"pasteboard":{"metadata":{"changeCount":next},"items":XPCObject::Array(items)}}).to_plist())?;
            board.writes+=1;
            if board.fail_set_ack {Err("Simulated lost write acknowledgement".into())} else {Ok(())}
        }
    }
    fn memory_lease()->(ClipboardLease<MemoryClient>,Arc<Mutex<MemoryBoard>>) {
        let original=parse_snapshot(&xpc!({"pasteboard":{"metadata":{"changeCount":41i64},"items":XPCObject::Array(vec![
            xpc!({"types":vec!["public.utf8-plain-text","public.html"],"data":{"public.utf8-plain-text":{"data":"original 中文".as_bytes()},"public.html":{"data":"<b>original 中文</b>".as_bytes()}}}),
            xpc!({"types":vec!["public.png"],"data":{"public.png":{"data":vec![137u8,80,78,71]}}}),
        ])}}).to_plist()).unwrap();
        let board=Arc::new(Mutex::new(MemoryBoard{snapshot:original.clone(),writes:0,remote:false,fail_set_ack:false,fail_payload:false}));
        (ClipboardLease{client:MemoryClient(board.clone()),original,owned_count:None,id:uuid::Uuid::new_v4().to_string(),text_hash:None,changed:false},board)
    }
    #[tokio::test]
    async fn held_paste_restores_all_formats_only_when_explicitly_finished() {
        let (mut lease,board)=memory_lease();
        lease.write("requested 中文🙂").await.unwrap();
        tokio::time::sleep(Duration::from_millis(550)).await;
        assert_eq!(board.lock().unwrap().snapshot.text().as_deref(),Some("requested 中文🙂"));
        assert_eq!(board.lock().unwrap().writes,1);
        assert!(lease.matches_text("requested 中文🙂"));
        assert!(!lease.matches_text("different text"));
        assert!(lease.restore().await.unwrap());
        assert!(same_contents(&lease.original,&board.lock().unwrap().snapshot));
        assert_eq!(board.lock().unwrap().writes,2);
    }
    #[tokio::test]
    async fn later_local_or_remote_copy_wins_over_restoration() {
        for remote in [false,true] {
            let (mut lease,board)=memory_lease();lease.write("requested").await.unwrap();
            {let mut b=board.lock().unwrap();b.snapshot.change_count=Some(100);b.remote=remote;}
            assert!(!lease.restore().await.unwrap());
            assert_eq!(board.lock().unwrap().writes,1,"Newer clipboard must not be overwritten");
        }
    }
    #[tokio::test]
    async fn uncertain_write_never_guesses_clipboard_ownership() {
        let (mut lease,board)=memory_lease();board.lock().unwrap().fail_set_ack=true;
        assert!(lease.write("requested").await.is_err());
        assert!(lease.restore().await.is_err());
        assert_eq!(board.lock().unwrap().writes,1);
    }
    #[tokio::test]
    async fn newer_unresolvable_copy_does_not_block_or_get_overwritten() {
        let (mut lease,board)=memory_lease();lease.write("requested").await.unwrap();
        {let mut b=board.lock().unwrap();b.snapshot.change_count=Some(100);b.fail_payload=true;}
        assert!(!lease.restore().await.unwrap());
        assert_eq!(board.lock().unwrap().writes,1);
    }
    #[tokio::test]
    async fn changed_unresolvable_original_is_rejected_before_any_write() {
        let (mut lease,board)=memory_lease();
        {let mut b=board.lock().unwrap();b.snapshot.change_count=Some(100);b.fail_payload=true;}
        assert!(lease.write("requested").await.unwrap_err().contains("changed before paste"));
        assert!(!lease.changed);
        assert_eq!(board.lock().unwrap().writes,0);
    }
    #[test]
    fn local_unresolvable_payload_needs_foreground_preparation_too() {
        assert!(needs_local_preparation("Clipboard payload unavailable; foreground preparation required"));
        assert!(needs_local_preparation("Remote-origin clipboard requires local preparation in SoloUse"));
        assert!(!needs_local_preparation("Clipboard changed before paste; please observe and retry"));
        let missing=xpc!({"pasteboard":{"metadata":{"changeCount":4i64}}}).to_plist();
        assert!(parse_snapshot(&missing).is_err(),"Missing payload is not an empty clipboard");
    }
    #[test]
    fn service_errors_are_not_empty_clipboard_snapshots() {
        let remote: plist::Value = plist::from_bytes(br#"<?xml version="1.0"?><plist version="1.0"><dict><key>error</key><dict><key>domain</key><string>com.apple.dt.CoreDeviceError</string><key>code</key><integer>26006</integer><key>userInfo</key><dict><key>NSLocalizedDescription</key><string>Blocked com.apple.is-remote-clipboard</string></dict></dict></dict></plist>"#).unwrap();
        assert!(parse_snapshot(&remote).unwrap_err().contains("Remote-origin"));
        let other: plist::Value = plist::from_bytes(br#"<?xml version="1.0"?><plist version="1.0"><dict><key>error</key><dict><key>code</key><integer>123</integer></dict></dict></plist>"#).unwrap();
        assert!(parse_snapshot(&other).is_err());
        let empty: plist::Value = plist::from_bytes(br#"<?xml version="1.0"?><plist version="1.0"><dict><key>pasteboard</key><dict><key>metadata</key><dict><key>changeCount</key><integer>4</integer></dict><key>items</key><array/></dict></dict></plist>"#).unwrap();
        let snapshot=parse_snapshot(&empty).unwrap();
        assert_eq!(snapshot.change_count,Some(4));
        assert!(snapshot.items.is_empty());
    }
    #[test]
    fn preserves_multiformat_bytes_and_rejects_unresolved_content() {
        let mut snapshot = PasteboardSnapshot {
            pasteboard_name: Some("general".into()),
            change_count: Some(3),
            items: vec![PasteboardItem {
                index: 0,
                types: vec!["public.utf8-plain-text".into()],
                data: vec![PasteboardEntry {
                    uti: "public.utf8-plain-text".into(),
                    payload: PasteboardPayload::Inline("中文🙂 MiXeD".as_bytes().into()),
                }],
            }],
        };
        assert!(encoded_items(&snapshot).is_ok());
        assert!(same_contents(&snapshot, &snapshot));
        assert_eq!(text_items("你好🙂").len(), 1);
        snapshot.items[0].data[0].payload = PasteboardPayload::Promised {
            size: Some(3_000_000),
        };
        assert!(encoded_items(&snapshot).is_err());
    }
}
