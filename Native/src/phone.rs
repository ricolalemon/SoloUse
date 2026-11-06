use super::*;
use futures_util::TryStreamExt;
use idevice::core_device::{MainKeyboardService, TOUCHSCREEN_STATE_RELEASE};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, serde::Serialize, Deserialize, PartialEq)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Action {
    ClipboardStatus,
    ClipboardProbe { policy: String },
    Observe,
    ReadTree,
    ListApps,
    OpenApp {
        app_id: String,
    },
    Tap {
        x: f64,
        y: f64,
        frame_id: String,
    },
    DoubleTap {
        x: f64,
        y: f64,
        frame_id: String,
    },
    LongPress {
        x: f64,
        y: f64,
        duration_ms: u64,
        frame_id: String,
    },
    Swipe {
        x: f64,
        y: f64,
        end_x: f64,
        end_y: f64,
        duration_ms: u64,
        frame_id: String,
    },
    TypeText {
        text: String,
    },
    PasteText {
        text: String,
        replace_all: bool,
    },
    PasteAt {
        text: String,
        x: f64,
        y: f64,
        frame_id: String,
    },
    FinishPaste { paste_id: String },
    PressKey {
        key: String,
    },
    Home,
    Wait {
        milliseconds: u64,
    },
}
impl Action {
    fn mutates(&self) -> bool {
        !matches!(self, Self::Observe | Self::ReadTree | Self::ListApps | Self::Wait { .. } | Self::ClipboardProbe { .. } | Self::ClipboardStatus)
    }
    fn validate(&self) -> bool {
        let point = |x: f64, y: f64| {
            x.is_finite() && y.is_finite() && (0.0..=1.0).contains(&x) && (0.0..=1.0).contains(&y)
        };
        match self {
            Self::ClipboardProbe {policy} => ["threshold","all_promised","all_resolved","match_source","resolve"].contains(&policy.as_str()),
            Self::Tap { x, y, .. } | Self::DoubleTap { x, y, .. } => point(*x, *y),
            Self::LongPress {
                x, y, duration_ms, ..
            } => point(*x, *y) && (300..=2000).contains(duration_ms),
            Self::Swipe {
                x,
                y,
                end_x,
                end_y,
                duration_ms,
                ..
            } => point(*x, *y) && point(*end_x, *end_y) && (100..=2000).contains(duration_ms),
            Self::OpenApp { app_id } => {
                !app_id.is_empty()
                    && app_id.len() <= 255
                    && app_id
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            }
            Self::TypeText { text } => text.len() <= 512,
            Self::PasteText { text, .. } => text.len() <= 16_384,
            Self::PasteAt { text, x, y, .. } => text.len() <= 16_384 && point(*x,*y),
            Self::FinishPaste { paste_id } => uuid::Uuid::parse_str(paste_id).is_ok(),
            Self::PressKey { key } => key.len() <= 100,
            Self::Wait { milliseconds } => (1..=5000).contains(milliseconds),
            _ => true,
        }
    }
    fn frame(&self) -> Option<&str> {
        match self {
            Self::Tap { frame_id, .. }
            | Self::DoubleTap { frame_id, .. }
            | Self::LongPress { frame_id, .. }
            | Self::PasteAt { frame_id, .. }
            | Self::Swipe { frame_id, .. } => Some(frame_id),
            _ => None,
        }
    }
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    session_id: String,
    id: String,
    action: Action,
}
#[derive(Default)]
struct Broker {
    session: Option<String>,
    queue: VecDeque<Request>,
    seen: HashMap<String, (Action, Option<Value>)>,
}
static BROKER: OnceLock<Mutex<Broker>> = OnceLock::new();
fn broker() -> &'static Mutex<Broker> {
    BROKER.get_or_init(Default::default)
}
pub(super) fn reset() {
    capture::clear();
    *broker().lock().unwrap() = Broker::default()
}
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 160
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
}
enum Enqueue {
    Queued,
    Replay(Value),
    Rejected(i32),
}
impl Broker {
    fn enqueue(&mut self, r: Request) -> Enqueue {
        if self.session.as_deref() != Some(r.session_id.as_str())
            || !valid_id(&r.id)
            || !r.action.validate()
        {
            return Enqueue::Rejected(-1);
        }
        if let Some((action, result)) = self.seen.get(&r.id) {
            if action != &r.action {
                return Enqueue::Rejected(-3);
            }
            return result
                .clone()
                .map(Enqueue::Replay)
                .unwrap_or(Enqueue::Rejected(-4));
        }
        if self.queue.len() >= 16 {
            return Enqueue::Rejected(-2);
        }
        self.seen.insert(r.id.clone(), (r.action.clone(), None));
        self.queue.push_back(r);
        Enqueue::Queued
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn solo_submit_command(raw: *const c_char) -> i32 {
    if raw.is_null() || CANCEL.load(Ordering::Acquire) {
        return -1;
    }
    let Ok(text) = (unsafe { CStr::from_ptr(raw) }).to_str() else {
        return -1;
    };
    if text.len() > 64_000 {
        return -1;
    }
    let Ok(request) = serde_json::from_str::<Request>(text) else {
        return -1;
    };
    let result = broker().lock().unwrap().enqueue(request);
    match result {
        Enqueue::Queued => 0,
        Enqueue::Replay(value) => {
            event("command_result", value);
            0
        }
        Enqueue::Rejected(code) => code,
    }
}
fn finish(request: &Request, status: &str, value: Value, error: Option<(&str, &str)>) -> Value {
    let mut result =
        json!({"session_id":request.session_id,"id":request.id,"status":status,"value":value});
    if let Some((code, message)) = error {
        result["error"] = json!({"code":code,"message":message,"retryable":status=="not_executed"});
    }
    result
}
fn fingerprint(action: &Action) -> String {
    format!("{:x}", Sha256::digest(serde_json::to_vec(action).unwrap()))
}

struct Journal {
    directory: PathBuf,
}
impl Journal {
    fn new(root: &std::path::Path, session: &str) -> Result<Self, String> {
        let directory = root.join("phone-journal").join(session);
        std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        Ok(Self { directory })
    }
    fn path(&self, id: &str) -> PathBuf {
        self.directory.join(format!("{id}.json"))
    }
    fn prior(&self, id: &str, action: &Action) -> Result<Option<Value>, String> {
        let path = self.path(id);
        if !path.exists() {
            return Ok(None);
        }
        let v: Value = serde_json::from_slice(&std::fs::read(path).map_err(|e| e.to_string())?)
            .map_err(|_| "Unreadable action receipt")?;
        if v["fingerprint"] != fingerprint(action) {
            return Err("Action id has a different payload".into());
        }
        Ok(Some(v["result"].clone()))
    }
    fn save(&self, id: &str, action: &Action, result: &Value) -> Result<(), String> {
        private_write(
            &self.path(id),
            &serde_json::to_vec(&json!({"fingerprint":fingerprint(action),"result":result}))
                .map_err(|e| e.to_string())?,
        )
    }
}

#[derive(Default)]
struct CommandTrace {
    stage: &'static str,
    input_started: bool,
    input_reports_sent: usize,
    indigo_pressed: Vec<u16>,
}
impl Action {
    fn name(&self) -> &'static str {
        match self {
            Self::ClipboardStatus => "clipboard_status",
            Self::ClipboardProbe { .. } => "clipboard_probe",
            Self::Observe => "observe",
            Self::ReadTree => "read_tree",
            Self::ListApps => "list_apps",
            Self::OpenApp { .. } => "open_app",
            Self::Tap { .. } => "tap",
            Self::DoubleTap { .. } => "double_tap",
            Self::LongPress { .. } => "long_press",
            Self::Swipe { .. } => "swipe",
            Self::TypeText { .. } => "type_text",
            Self::PressKey { .. } => "press_key",
            Self::PasteText { .. } => "paste_text",
            Self::PasteAt { .. } => "paste_at",
            Self::FinishPaste { .. } => "finish_paste",
            Self::Home => "home",
            Self::Wait { .. } => "wait",
        }
    }
}

pub(super) async fn run(c: &Config) -> Result<(), String> {
    let session = c.session_id.as_deref().ok_or("Missing session id")?;
    let journal = Journal::new(&c.directory, session)?;
    let (mut adapter, mut rsd) = connect(c).await?;
    let result=async {
        let media=media::MediaSession::open(&mut adapter,&mut rsd,&c.directory).await?;
        let outcome=async {
            let mut hid=bounded("hid_service",12,UniversalHidServiceClient::connect_rsd(&mut adapter,&mut rsd)).await?;
            let mut buttons=bounded("button_service",12,IndigoHidClient::connect_rsd(&mut adapter,&mut rsd)).await?;
            broker().lock().unwrap().session=Some(session.into());
            let mut capabilities=vec!["screenshot","app_inventory","tap","double_tap","long_press","swipe","ascii_hardware_keys","key_chords","home"];
            let mut unsupported=vec!["verified_foreground_app"];
            capabilities.push("accessibility_tree_optional");
            if rsd.services.contains_key("com.apple.coredevice.pasteboardservice") { capabilities.push("clipboard_paste"); }
            else { unsupported.push("clipboard_paste"); }
            event("session_ready",json!({"session_id":session,"read_only":c.read_only,"capabilities":capabilities,"unsupported":unsupported}));
            let mut frame:Option<(String,u32,u32,Instant)>=None;
            let mut apps:Option<HashSet<String>>=None;
            let mut capture=capture::CaptureSession::default();
            let mut tree=accessibility::TreeSession::new(&c.bundle_prefix);
            let mut session_keyboard=None;
            let mut clipboard_lease:Option<clipboard::ClipboardLease>=None;
            let loop_outcome:Result<(),String>=async { loop {
                if CANCEL.load(Ordering::Acquire){return Err("Cancelled".into())}
                if let Some(error)=media.failure(){return Err(error)}
                let request=broker().lock().unwrap().queue.pop_front();
                let Some(request)=request else{tokio::time::sleep(Duration::from_millis(25)).await;continue};
                event("command_started",json!({"session_id":session,"id":request.id,"operation":request.action.name()}));
                let validation=if c.read_only && request.action.mutates(){Some(("permission_denied","This session is read-only"))}
                    else if let Some(id)=request.action.frame(){
                        match &frame {
                            Some((current,w,h,when)) if current==id && when.elapsed()<Duration::from_secs(60) && h>=w=>None,
                            Some((_,w,h,_)) if w>h=>Some(("unsupported_orientation","Coordinate input in landscape is not validated")),
                            _=>Some(("stale_frame","Observe again before using coordinates")),
                        }
                    } else{None};
                let mut response=if let Some(error)=validation{finish(&request,"not_executed",Value::Null,Some(error))}
                else if let Some(old)=journal.prior(&request.id,&request.action)?{old}
                else if let Some(error)=validate_pending_paste(&request.action,clipboard_lease.as_ref()) {
                    finish(&request,"not_executed",Value::Null,Some(error))
                }
                else if let Err(code)=check_pending_clipboard(&request.action,&mut clipboard_lease,&mut adapter,&mut rsd).await {
                    finish(&request,"not_executed",Value::Null,Some((code,"Pending paste clipboard changed or could not be checked. No UI action was sent. Observe again; do not accept a stale paste-permission prompt.")))
                }
                else {
                    // Validate input before journaling an irreversible/uncertain effect.
                    let support=match &request.action {
                        Action::TypeText{text}=>text.chars().all(|ch|ascii_chord(ch).is_ok()),
                        Action::PressKey{key}=>parse_chord(key).is_ok(),_=>true};
                    if !support{finish(&request,"not_executed",Value::Null,Some(("unsupported_input","Use supported hardware keys/chords, or phone_paste_text for literal Unicode text")))}
                    else if let Err(code)=preflight_app(&request.action,&mut adapter,&mut rsd,&mut apps).await {
                        finish(&request,"not_executed",Value::Null,Some((code,"Could not find the app in the device inventory; list apps and retry")))
                    } else {
                        if CANCEL.load(Ordering::Acquire){return Err("Cancelled".into())}
                        if request.action.mutates(){journal.save(&request.id,&request.action,&finish(&request,"may_have_executed",Value::Null,Some(("interrupted","Execution may have started; do not repeat blindly"))))?;}
                        let mut key_service=if matches!(request.action, Action::TypeText{..}|Action::PasteText{..}|Action::PressKey{..}) {session_keyboard.take()} else {None};
                        let mut trace=CommandTrace{stage:"dispatch",..Default::default()};
                        let command_started=Instant::now();
                        let command=execute(&c.keyboard_tuning,&request.action,&mut adapter,&mut rsd,&mut hid,&mut buttons,&mut frame,&mut capture,&mut tree,&mut apps,&mut key_service,&mut clipboard_lease,&mut trace);
                        let deadline=match request.action {Action::ClipboardStatus=>3,Action::ClipboardProbe{..}=>75,Action::ReadTree=>65,_=>45};
                        let mut result=tokio::select!{ result=tokio::time::timeout(Duration::from_secs(deadline),command)=>result.map_err(|_|"Command timed out".to_string()).and_then(|x|x), _=cancellation()=>Err("Cancelled".into()) };
                        let raw_error=result.as_ref().err().cloned();
                        let failed_stage=trace.stage;
                        let mut cleanup_errors=Vec::new();
                        // Cleanup owns the keyboard outside the cancellable future.
                        // After a transport failure cleanup is best-effort; never replay the action.
                        for usage in trace.indigo_pressed.drain(..).rev() {
                            let released=tokio::time::timeout(Duration::from_secs(2),buttons.send_keyboard(usage as u64,ButtonState::Up)).await;
                            if !matches!(released,Ok(Ok(()))) {cleanup_errors.push("indigo_release_failed".into());result=Err("Keyboard cleanup could not be confirmed".into());}
                        }
                        if let Some(mut key)=key_service {
                            let release=tokio::time::timeout(Duration::from_secs(2),hid.set_main_keyboard_usages(&mut key,Vec::<KeyboardUsage>::new())).await;
                            if !matches!(release,Ok(Ok(()))){cleanup_errors.push("keyboard_release_failed".into());}
                            if c.keyboard_tuning.keep_connected && result.is_ok() && cleanup_errors.is_empty() {
                                session_keyboard=Some(key);
                                event("keyboard_stage",json!({"stage":"retained","reports":trace.input_reports_sent}));
                            } else {
                            let reset=tokio::time::timeout(Duration::from_secs(2),hid.reset_main_keyboard(&mut key)).await;
                            let remove=tokio::time::timeout(Duration::from_secs(2),hid.remove_main_keyboard(&mut key)).await;
                            if let Err(error)=&reset{cleanup_errors.push(format!("keyboard_reset_timeout: {error}"));}
                            if let Ok(Err(error))=&reset{cleanup_errors.push(format!("keyboard_reset: {error}"));}
                            if let Err(error)=&remove{cleanup_errors.push(format!("keyboard_remove_timeout: {error}"));}
                            if let Ok(Err(error))=&remove{cleanup_errors.push(format!("keyboard_remove: {error}"));}
                            if !cleanup_errors.is_empty(){result=Err("Keyboard cleanup could not be confirmed".into());}
                            event("keyboard_stage",json!({"stage":"removed","reports":trace.input_reports_sent}));
                            }
                        }
                        let clipboard_may_have_changed=clipboard_lease.as_ref().is_some_and(|p:&clipboard::ClipboardLease|p.changed);
                        // The clipboard is held across observations/model turns.
                        // finish_paste or session cleanup owns its restoration.
                        if result.is_err() {
                            if let Action::Tap{x,y,..}|Action::DoubleTap{x,y,..}|Action::LongPress{x,y,..}|Action::Swipe{x,y,..}|Action::PasteAt{x,y,..}=&request.action {
                                let _=tokio::time::timeout(Duration::from_secs(2),hid.send_touchscreen(TOUCHSCREEN_STATE_RELEASE,normalized(*x)?,normalized(*y)?,None)).await;
                            }
                            if matches!(request.action,Action::Home){let _=tokio::time::timeout(Duration::from_secs(2),buttons.send_button(0x0c,0x40,ButtonState::Up)).await;}
                        }
                        match result {
                            Ok(value)=>finish(&request,"executed",value,None),
                            Err(error)=>{
                                let timeout=error.to_ascii_lowercase().contains("timed out") || error.contains("timeout");
                                let clipboard_unavailable=clipboard::needs_local_preparation(&error) && !trace.input_started && !clipboard_may_have_changed;
                                let code=if clipboard_unavailable{"clipboard_preparation_required"}else if timeout{"operation_timeout"}else{"driver_error"};
                                let message=if matches!(request.action,Action::ListApps){
                                    if timeout{"Application inventory timed out. Use Home and the phone's search UI instead of repeatedly listing apps."}
                                    else{"Application inventory could not be read. Use Home and the phone's search UI."}
                                } else if clipboard_unavailable {"The original clipboard contents could not be backed up. Return to SoloUse and resume for foreground clipboard preparation; repeating paste on this unchanged clipboard will not help. No paste keys were sent and the original clipboard was not changed."}
                                else {"Phone operation did not complete; inspect the screen before deciding what to do next"};
                                event("command_failed",json!({"session_id":session,"id":request.id,"code":code,"mutating":request.action.mutates(),
                                    "operation":request.action.name(),"stage":failed_stage,"cancel_requested":CANCEL.load(Ordering::Acquire),
                                    "input_started":trace.input_started,"input_reports_sent":trace.input_reports_sent,
                                    "elapsed_ms":command_started.elapsed().as_millis() as u64,
                                    "raw_error":raw_error.as_deref().unwrap_or(&error),"cleanup_error":cleanup_errors.join("; ")}));
                                finish(&request,if request.action.mutates() && (!matches!(request.action,Action::PasteText{..}|Action::PasteAt{..}) || trace.input_started || clipboard_may_have_changed){"may_have_executed"}else{"not_executed"},Value::Null,Some((code,message)))
                            },
                        }
                    }
                };
                if let Some(lease)=clipboard_lease.as_ref().filter(|lease|lease.changed) {
                    if !response["value"].is_object() {response["value"]=json!({});}
                    response["value"]["clipboard_pending"]=json!(true);
                    response["value"]["pending_paste_id"]=json!(lease.id);
                } else if response["value"]["clipboard_pending"]==true {
                    // A replayed receipt does not resurrect a released lease.
                    response["value"]["clipboard_pending"]=json!(false);
                    response["value"].as_object_mut().unwrap().remove("pending_paste_id");
                }
                if request.action.mutates(){journal.save(&request.id,&request.action,&response)?;}
                if let Some(record)=broker().lock().unwrap().seen.get_mut(&request.id){record.1=Some(response.clone());}
                event("command_result",response);
            }}.await;
            let clipboard_cleanup=if let Some(mut lease)=clipboard_lease.take() {
                let restored=tokio::time::timeout(Duration::from_secs(6),async {
                    lease.reconnect(&mut adapter,&mut rsd).await?;
                    lease.restore().await
                }).await;
                match restored {
                    Ok(Ok(ok))=>{event("clipboard_stage",json!({"stage":"session_cleanup","paste_id":lease.id,"clipboard_restored":ok,"newer_clipboard_preserved":!ok}));Ok(())},
                    _=>{event("clipboard_stage",json!({"stage":"cleanup_failed","paste_id":lease.id}));Err("Clipboard restoration was not confirmed at session end".to_string())},
                }
            } else {Ok(())};
            if let Some(mut key)=session_keyboard {
                let _=tokio::time::timeout(Duration::from_secs(2),hid.set_main_keyboard_usages(&mut key,Vec::<KeyboardUsage>::new())).await;
                let _=tokio::time::timeout(Duration::from_secs(2),hid.remove_main_keyboard(&mut key)).await;
                event("keyboard_stage",json!({"stage":"session_removed"}));
            }
            tree.close().await;
            clipboard_cleanup.and(loop_outcome)
        }.await;
        media.close().await;outcome
    }.await;
    let _ = tokio::time::timeout(Duration::from_secs(5), adapter.close()).await;
    reset();
    result
}

type Hid = UniversalHidServiceClient<Box<dyn idevice::ReadWrite>>;
type Buttons = IndigoHidClient<Box<dyn idevice::ReadWrite>>;
fn validate_pending_paste(action:&Action, lease:Option<&clipboard::ClipboardLease>) -> Option<(&'static str,&'static str)> {
    match action {
        Action::FinishPaste{paste_id} if lease.is_none_or(|lease|&lease.id!=paste_id)=>Some(("paste_not_pending","This paste is no longer pending. Observe the current state; do not replay the original input.")),
        Action::PasteText{text,..}|Action::PasteAt{text,..} if lease.is_some_and(|lease|!lease.matches_text(text))=>Some(("paste_in_progress","Finish the existing paste_id after verifying input or dismissing its permission prompt, before staging different text.")),
        _=>None,
    }
}
async fn check_pending_clipboard(action:&Action, lease:&mut Option<clipboard::ClipboardLease>,a:&mut AdapterHandle,r:&mut RsdHandshake) -> Result<(), &'static str> {
    if !action.mutates() || matches!(action,Action::FinishPaste{..}) {return Ok(());}
    let Some(pending)=lease.as_mut() else {return Ok(());};
    let result=tokio::select! {
        result=tokio::time::timeout(Duration::from_secs(3),async {pending.reconnect(a,r).await?;pending.still_owned().await})=>result,
        _=cancellation()=>return Err("cancelled"),
    };
    match result {
        Ok(Ok(true))=>Ok(()),
        Ok(Ok(false))=>{event("clipboard_stage",json!({"stage":"newer_copy_preserved","paste_id":pending.id}));*lease=None;Err("clipboard_changed")},
        _=>Err("clipboard_check_failed"),
    }
}
async fn execute(
    tuning: &KeyboardTuning,
    action: &Action,
    a: &mut AdapterHandle,
    r: &mut RsdHandshake,
    hid: &mut Hid,
    buttons: &mut Buttons,
    frame: &mut Option<(String, u32, u32, Instant)>,
    capture: &mut capture::CaptureSession,
    tree: &mut accessibility::TreeSession,
    known_apps: &mut Option<HashSet<String>>,
    key_service: &mut Option<MainKeyboardService>,
    clipboard_lease: &mut Option<clipboard::ClipboardLease>,
    trace: &mut CommandTrace,
) -> Result<Value, String> {
    match action {
        Action::ClipboardStatus => {
            trace.stage="clipboard_status";
            clipboard::status(a,r).await
        }
        Action::ClipboardProbe { policy } => {
            trace.stage="clipboard_read_probe";
            clipboard::probe(a,r,policy).await
        }
        Action::Observe | Action::ReadTree => {
            let accessibility = if matches!(action, Action::ReadTree) {
                trace.stage = "accessibility_tree";
                Some(tree.read(a,r).await)
            } else {None};
            trace.stage = "screenshot";
            let data = capture.take(a, r).await?;
            let (width, height) = capture::dimensions(&data)?;
            let id = uuid::Uuid::new_v4().to_string();
            *frame = Some((id.clone(), width, height, Instant::now()));
            capture::store(id.clone(), data);
            let mut result=json!({"frame_buffer":id,"frame_id":id,"width":width,"height":height,"orientation":if width>height{"landscape"}else{"portrait"}});
            if let Some(tree)=accessibility {result["accessibility"]=tree;}
            Ok(result)
        }
        Action::ListApps => {
            trace.stage = "app_inventory";
            let list = fetch_apps(a, r).await?;
            *known_apps = Some(
                list.iter()
                    .map(|app| app.bundle_identifier.clone())
                    .collect(),
            );
            Ok(
                json!({"apps":list.into_iter().map(|app|json!({"id":app.bundle_identifier,"name":app.name})).collect::<Vec<_>>()}),
            )
        }
        Action::OpenApp { app_id } => {
            trace.stage = "app_service_connect";
            let mut service = AppServiceClient::connect_rsd(a, r)
                .await
                .map_err(|e| e.to_string())?;
            trace.stage = "app_launch";
            service
                .launch_application(app_id, &[], false, false, None, None, None)
                .await
                .map_err(|e| e.to_string())?;
            *frame = None;
            Ok(json!({"opened":app_id}))
        }
        Action::Tap { x, y, .. } | Action::DoubleTap { x, y, .. } => {
            let count = if matches!(action, Action::DoubleTap { .. }) {
                2
            } else {
                1
            };
            for _ in 0..count {
                trace.stage = "touch_tap";
                hid.tap(normalized(*x)?, normalized(*y)?)
                    .await
                    .map_err(|e| e.to_string())?;
            }
            Ok(json!({"tap_count":count}))
        }
        Action::LongPress {
            x, y, duration_ms, ..
        } => {
            trace.stage = "touch_drag";
            hid.drag(
                normalized(*x)?,
                normalized(*y)?,
                normalized(*x)?,
                normalized(*y)?,
                20,
                *duration_ms / 20,
            )
            .await
            .map_err(|e| e.to_string())?;
            Ok(json!({}))
        }
        Action::Swipe {
            x,
            y,
            end_x,
            end_y,
            duration_ms,
            ..
        } => {
            trace.stage = "touch_drag";
            hid.drag(
                normalized(*x)?,
                normalized(*y)?,
                normalized(*end_x)?,
                normalized(*end_y)?,
                20,
                *duration_ms / 20,
            )
            .await
            .map_err(|e| e.to_string())?;
            Ok(json!({}))
        }
        Action::TypeText { text } => {
            keyboard(
                tuning,
                hid,
                buttons,
                key_service,
                trace,
                text.chars()
                    .map(ascii_chord)
                    .collect::<Result<Vec<_>, _>>()?,
            )
            .await?;
            Ok(
                json!({"input_method":"hardware_keys","characters":text.chars().count(),"verification_required":true}),
            )
        }
        Action::PasteText { text, .. } | Action::PasteAt { text, .. } => {
            trace.stage = "clipboard_prepare";
            if clipboard_lease.is_none() {
                *clipboard_lease = Some(clipboard::ClipboardLease::prepare(a, r).await?);
                trace.stage = "clipboard_write";
                if let Err(error)=clipboard_lease.as_mut().unwrap().write(text).await {
                    if !clipboard_lease.as_ref().unwrap().changed { *clipboard_lease=None; }
                    return Err(error);
                }
            }
            let replace_all=matches!(action,Action::PasteText{replace_all:true,..});
            if let Action::PasteAt{x,y,..}=action {
                // Tap a model-observed Paste control. Its normal UI gesture
                // supplies paste intent without a target-app-specific path.
                trace.stage="clipboard_paste_control";
                trace.input_started=true;
                hid.tap(normalized(*x)?,normalized(*y)?).await.map_err(|e|e.to_string())?;
            } else {
                let mut keys = Vec::new();
                if replace_all { keys.push(parse_chord("cmd+a")?); }
                keys.push(parse_chord("cmd+v")?);
                let paste_tuning=KeyboardTuning {indigo:tuning.paste_indigo,..*tuning};
                keyboard(&paste_tuning, hid, buttons, key_service, trace, keys).await?;
            }
            // Allow normal UI delivery, but never restore on a fixed timer.
            // The model can inspect/resolve a permission prompt in later turns.
            trace.stage = "clipboard_paste_delivery";
            tokio::time::sleep(Duration::from_millis(tuning.paste_ms)).await;
            Ok(
                json!({"input_method":if matches!(action,Action::PasteAt{..}) {"clipboard_paste_control"} else {"clipboard_paste"},"characters":text.chars().count(),"replace_all":replace_all,"verification_required":true,"paste_id":clipboard_lease.as_ref().unwrap().id,"clipboard_pending":true,"next_step":"Observe and handle any permission dialog for this requested text. After verifying insertion (or dismissing the dialog to abandon it), call finish_paste with this paste_id. Do not repeat input blindly."}),
            )
        }
        Action::FinishPaste{paste_id}=>{
            trace.stage="clipboard_finish";
            let lease=clipboard_lease.as_mut().ok_or("No pending paste")?;
            lease.reconnect(a,r).await?;
            let restored=lease.restore().await?;
            event("clipboard_stage",json!({"stage":"finished","paste_id":paste_id,"clipboard_restored":restored,"newer_clipboard_preserved":!restored}));
            *clipboard_lease=None;
            Ok(json!({"paste_id":paste_id,"clipboard_pending":false,"clipboard_restored":restored,"newer_clipboard_preserved":!restored}))
        }
        Action::PressKey { key } => {
            let chord=parse_chord(key)?;
            let selected=if chord.contains(&0x19) && chord.iter().any(|key|[0xe3,0xe7].contains(key)) {
                KeyboardTuning {indigo:tuning.paste_indigo,..*tuning}
            } else {*tuning};
            keyboard(&selected, hid, buttons, key_service, trace, vec![chord]).await?;
            Ok(json!({}))
        }
        Action::Home => {
            trace.stage = "home_down";
            buttons
                .send_button(0x0c, 0x40, ButtonState::Down)
                .await
                .map_err(|e| e.to_string())?;
            tokio::time::sleep(Duration::from_millis(60)).await;
            trace.stage = "home_up";
            buttons
                .send_button(0x0c, 0x40, ButtonState::Up)
                .await
                .map_err(|e| e.to_string())?;
            *frame = None;
            Ok(json!({}))
        }
        Action::Wait { milliseconds } => {
            trace.stage = "wait";
            tokio::time::sleep(Duration::from_millis(*milliseconds)).await;
            Ok(json!({"waited_ms":milliseconds}))
        }
    }
}

fn inventory_streaming(features: Option<&[String]>) -> bool {
    features.is_some_and(|items| {
        items
            .iter()
            .any(|name| name == "com.apple.coredevice.feature.streamapplist")
    })
}
async fn fetch_apps(
    a: &mut AdapterHandle,
    r: &mut RsdHandshake,
) -> Result<Vec<idevice::core_device::AppListEntry>, String> {
    // iOS 27 accepts legacy listapps but can leave it waiting forever. Follow
    // the advertised capability, as the pinned upstream CLI does.
    let stream = inventory_streaming(
        r.services
            .get(AppServiceClient::rsd_service_name().as_ref())
            .and_then(|service| service.features.as_deref()),
    );
    let mut service = bounded(
        "app_inventory_connect",
        5,
        AppServiceClient::connect_rsd(a, r),
    )
    .await?;
    let started = Instant::now();
    let result = if stream {
        bounded(
            "app_inventory_stream",
            10,
            service
                .stream_apps(false, true, false, false, true)
                .try_collect(),
        )
        .await
    } else {
        bounded(
            "app_inventory_legacy",
            10,
            service.list_apps(false, true, false, false, true),
        )
        .await
    };
    event(
        "app_inventory_result",
        json!({"transport":if stream{"streamapplist"}else{"listapps"},
        "elapsed_ms":started.elapsed().as_millis() as u64,"ok":result.is_ok(),
        "count":result.as_ref().map(|apps:&Vec<idevice::core_device::AppListEntry>|apps.len()).unwrap_or(0)}),
    );
    result
}

async fn preflight_app(
    action: &Action,
    a: &mut AdapterHandle,
    r: &mut RsdHandshake,
    apps: &mut Option<HashSet<String>>,
) -> Result<(), &'static str> {
    let Action::OpenApp { app_id } = action else {
        return Ok(());
    };
    if apps.as_ref().is_some_and(|list| list.contains(app_id)) {
        return Ok(());
    }
    let fetch = async {
        *apps = Some(
            fetch_apps(a, r)
                .await
                .map_err(|_| "inventory_unavailable")?
                .into_iter()
                .map(|app| app.bundle_identifier)
                .collect(),
        );
        if apps.as_ref().unwrap().contains(app_id) {
            Ok(())
        } else {
            Err("app_not_found")
        }
    };
    tokio::select! {r=tokio::time::timeout(Duration::from_secs(15),fetch)=>r.unwrap_or(Err("inventory_timeout")),_=cancellation()=>Err("cancelled")}
}

async fn keyboard(
    tuning: &KeyboardTuning,
    hid: &mut Hid,
    buttons: &mut Buttons,
    service: &mut Option<MainKeyboardService>,
    trace: &mut CommandTrace,
    chords: Vec<Vec<u16>>,
) -> Result<(), String> {
    if tuning.indigo {
        event("keyboard_stage",json!({"stage":"indigo_send_started"}));
        for chord in chords {
            for report in chord_reports(&chord) {
                if CANCEL.load(Ordering::Acquire) {return Err("Cancelled".into());}
                trace.stage="indigo_keyboard_report";
                trace.input_started=true;
                for key in trace.indigo_pressed.clone().into_iter().filter(|key|!report.contains(key)) {
                    buttons.send_keyboard(key as u64,ButtonState::Up).await.map_err(|e|e.to_string())?;
                    trace.indigo_pressed.retain(|held|*held!=key);
                }
                for key in report {
                    if !trace.indigo_pressed.contains(&key) {
                        trace.indigo_pressed.push(key);
                        buttons.send_keyboard(key as u64,ButtonState::Down).await.map_err(|e|e.to_string())?;
                    }
                }
                trace.input_reports_sent+=1;
                tokio::time::sleep(Duration::from_millis(60)).await;
            }
        }
        event("keyboard_stage",json!({"stage":"indigo_send_finished","reports":trace.input_reports_sent}));
        return Ok(());
    }
    trace.stage = "keyboard_create";
    if service.is_none() {
        *service = Some(hid.create_main_keyboard().await.map_err(|e| e.to_string())?);
        event("keyboard_stage", json!({"stage":"registered","setup_ms":tuning.setup_ms}));
        tokio::time::sleep(Duration::from_millis(tuning.setup_ms)).await;
    }
    let keyboard = service.as_mut().unwrap();
    event("keyboard_stage",json!({"stage":"send_started"}));
    for chord in chords {
        for report in chord_reports(&chord) {
            if CANCEL.load(Ordering::Acquire) {
                return Err("Cancelled".into());
            }
            let keys = report
                .into_iter()
                .map(|key| KeyboardUsage::new(key).map_err(|e| e.to_string()))
                .collect::<Result<Vec<_>, _>>()?;
            trace.stage = "keyboard_report";
            trace.input_started = true;
            hid.set_main_keyboard_usages(keyboard, keys)
                .await
                .map_err(|e| e.to_string())?;
            trace.input_reports_sent += 1;
            tokio::time::sleep(Duration::from_millis(60)).await;
        }
    }
    event("keyboard_stage",json!({"stage":"send_finished","reports":trace.input_reports_sent}));
    Ok(())
}
fn chord_reports(chord: &[u16]) -> Vec<Vec<u16>> {
    let modifiers = chord
        .iter()
        .copied()
        .filter(|key| (0xe0..=0xe7).contains(key))
        .collect::<Vec<_>>();
    if modifiers.is_empty() {
        vec![chord.to_vec(), vec![]]
    } else {
        vec![modifiers.clone(), chord.to_vec(), modifiers, vec![]]
    }
}

fn ascii_chord(ch: char) -> Result<Vec<u16>, String> {
    let (key, shift) = match ch {
        'a'..='z' => (4 + ch as u16 - 'a' as u16, false),
        'A'..='Z' => (4 + ch as u16 - 'A' as u16, true),
        '1'..='9' => (0x1e + ch as u16 - '1' as u16, false),
        '0' => (0x27, false),
        ' ' => (0x2c, false),
        '\n' | '\r' => (0x28, false),
        '\t' => (0x2b, false),
        _ => {
            let lower = "-=[]\\;'`,./";
            let upper = "_+{}|:\"~<>?";
            let usages = [
                0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
            ];
            if let Some(i) = lower.chars().position(|c| c == ch) {
                (usages[i], false)
            } else if let Some(i) = upper.chars().position(|c| c == ch) {
                (usages[i], true)
            } else if let Some(i) = "!@#$%^&*()".chars().position(|c| c == ch) {
                (if i == 9 { 0x27 } else { 0x1e + i as u16 }, true)
            } else {
                return Err("Character is unsupported by hardware-key input".into());
            }
        }
    };
    Ok(if shift { vec![0xe1, key] } else { vec![key] })
}
fn parse_chord(text: &str) -> Result<Vec<u16>, String> {
    let parts = text.split('+').collect::<Vec<_>>();
    let mut keys = Vec::new();
    for (index, part) in parts.iter().enumerate() {
        let last = index + 1 == parts.len();
        let modifier = match part.to_ascii_lowercase().as_str() {
            "cmd" | "super" | "command" => Some(0xe3),
            "ctrl" | "control" => Some(0xe0),
            "alt" | "option" => Some(0xe2),
            "shift" => Some(0xe1),
            _ => None,
        };
        if let Some(key) = modifier {
            keys.push(key);
            continue;
        }
        if !last {
            return Err("Modifiers must precede the key".into());
        }
        let key = match part.to_ascii_lowercase().as_str() {
            "return" | "enter" => 0x28,
            "escape" | "esc" => 0x29,
            "backspace" => 0x2a,
            "tab" => 0x2b,
            "space" => 0x2c,
            "home" => 0x4a,
            "pageup" => 0x4b,
            "delete" => 0x4c,
            "end" => 0x4d,
            "pagedown" => 0x4e,
            "right" => 0x4f,
            "left" => 0x50,
            "down" => 0x51,
            "up" => 0x52,
            _ => {
                if part.chars().count() != 1 {
                    return Err("Unsupported key".into());
                }
                keys.extend(ascii_chord(part.chars().next().unwrap())?);
                continue;
            }
        };
        keys.push(key);
    }
    keys.sort_unstable();
    keys.dedup();
    if keys.is_empty() || keys.len() > 4 {
        return Err("Invalid key chord".into());
    }
    Ok(keys)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(id: &str, action: Action) -> Request {
        Request {
            session_id: "session".into(),
            id: id.into(),
            action,
        }
    }
    #[test]
    fn ids_are_session_bound_and_replayed_without_reexecution() {
        let mut b = Broker {
            session: Some("session".into()),
            ..Default::default()
        };
        let r = request("once", Action::Home);
        assert!(matches!(b.enqueue(r.clone()), Enqueue::Queued));
        assert!(matches!(b.enqueue(r.clone()), Enqueue::Rejected(-4)));
        b.seen.get_mut("once").unwrap().1 = Some(json!({"status":"executed"}));
        assert!(matches!(b.enqueue(r), Enqueue::Replay(_)));
        assert!(matches!(
            b.enqueue(request("once", Action::Observe)),
            Enqueue::Rejected(-3)
        ));
        let mut wrong = request("new", Action::Home);
        wrong.session_id = "old".into();
        assert!(matches!(b.enqueue(wrong), Enqueue::Rejected(-1)));
    }
    #[test]
    fn long_session_has_no_total_command_cap_and_retains_old_receipts() {
        let mut b = Broker {
            session: Some("session".into()),
            ..Default::default()
        };
        for index in 0..300 {
            let id = format!("step_{index}");
            assert!(matches!(
                b.enqueue(request(&id, Action::Home)),
                Enqueue::Queued
            ));
            b.queue.pop_front();
            b.seen.get_mut(&id).unwrap().1 = Some(json!({"status":"executed"}));
        }
        assert!(matches!(
            b.enqueue(request("step_0", Action::Home)),
            Enqueue::Replay(_)
        ));
        assert!(matches!(
            b.enqueue(request("step_0", Action::Observe)),
            Enqueue::Rejected(-3)
        ));
    }
    #[test]
    fn task_content_is_not_restricted_to_specific_apps_or_messages() {
        for text in ["arbitrary task 73", "HELLO, world!", "中文🙂"] {
            assert!(Action::TypeText { text: text.into() }.validate());
        }
        for id in ["com.example.notes", "org.example.reader"] {
            assert!(Action::OpenApp { app_id: id.into() }.validate());
        }
        assert!(
            !Action::OpenApp {
                app_id: "../../secret".into()
            }
            .validate()
        );
        assert!(
            !Action::Tap {
                x: f64::NAN,
                y: 0.5,
                frame_id: "f".into()
            }
            .validate()
        );
    }
    #[test]
    fn key_chords_preserve_modifiers_and_reject_unsupported_input() {
        assert_eq!(ascii_chord('A').unwrap(), vec![0xe1, 4]);
        assert_eq!(ascii_chord('?').unwrap(), vec![0xe1, 0x38]);
        assert_eq!(parse_chord("cmd+a").unwrap(), vec![4, 0xe3]);
        assert_eq!(
            chord_reports(&[4, 0xe3]),
            vec![vec![0xe3], vec![4, 0xe3], vec![0xe3], vec![]]
        );
        assert_eq!(chord_reports(&[4]), vec![vec![4], vec![]]);
        assert_eq!(parse_chord("shift+Left").unwrap(), vec![0x50, 0xe1]);
        assert!(ascii_chord('中').is_err());
        assert!(parse_chord("a+b").is_err());
    }
    #[test]
    fn clipboard_preparation_is_read_only_and_paste_controls_require_valid_coordinates() {
        let action: Action=serde_json::from_str(r#"{"op":"clipboard_status"}"#).unwrap();
        assert!(action.validate());
        assert!(!action.mutates());
        let action:Action=serde_json::from_str(r#"{"op":"paste_at","text":"中文🙂","x":0.25,"y":0.5,"frame_id":"f1"}"#).unwrap();
        assert!(action.validate()); assert!(action.mutates()); assert_eq!(action.frame(),Some("f1"));
        assert!(!Action::PasteAt{text:"x".into(),x:1.1,y:0.5,frame_id:"f1".into()}.validate());
    }
    #[test]
    fn uncertain_journal_receipt_survives_reopening() {
        let root = std::env::temp_dir().join(format!("solouse-journal-{}", uuid::Uuid::new_v4()));
        let j = Journal::new(&root, "session").unwrap();
        let r = request("one", Action::Home);
        let unknown = finish(&r, "may_have_executed", Value::Null, None);
        j.save(&r.id, &r.action, &unknown).unwrap();
        let reopened = Journal::new(&root, "session").unwrap();
        assert_eq!(reopened.prior("one", &Action::Home).unwrap(), Some(unknown));
        assert!(reopened.prior("one", &Action::Observe).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
