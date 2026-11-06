//! Optional XCTest snapshot companion. All orchestration runs on the iPhone
//! over its already-authenticated RSD tunnel; transport is loopback + per-run token.
use super::*;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use idevice::{dvt::xctest::{TestConfig, run_on_rsd, listener::XCUITestListener}, installation_proxy::InstallationProxyClient};
use tokio::io::{AsyncReadExt, AsyncWriteExt, AsyncBufReadExt, BufReader};

#[derive(Default)]
pub(super) struct TreeSession {
    bundle_prefix: String,
    task: Option<tokio::task::JoinHandle<Result<(), String>>>,
    token: String,
}
struct Listener;
impl XCUITestListener for Listener {
    async fn setup_stage(&mut self, stage:&str)->Result<(),idevice::IdeviceError>{phase(stage);Ok(())}
    async fn did_begin_executing_test_plan(&mut self)->Result<(),idevice::IdeviceError>{phase("tree_plan_began");Ok(())}
    async fn test_case_did_start(&mut self,_class:&str,_method:&str)->Result<(),idevice::IdeviceError>{phase("tree_test_began");Ok(())}
    async fn initialization_for_ui_testing_did_fail(&mut self, description:&str)->Result<(),idevice::IdeviceError>{
        Err(idevice::IdeviceError::UnexpectedResponse(format!("Tree UI testing initialization failed: {description}")))
    }
}

impl TreeSession {
    pub(super) fn new(bundle_prefix: &str) -> Self { { let mut value = Self::default(); value.bundle_prefix = bundle_prefix.into(); value } }
    async fn request(&self, op: &str) -> Result<Value, String> {
        let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, 49281)).await.map_err(|e| e.to_string())?;
        let nonce=uuid::Uuid::new_v4().simple().to_string();
        let mac=signature(&self.token,&format!("request\n{nonce}\n{op}"));
        let mut bytes = serde_json::to_vec(&json!({"nonce":nonce,"op":op,"mac":mac})).map_err(|e|e.to_string())?;
        bytes.push(b'\n');
        stream.write_all(&bytes).await.map_err(|e|e.to_string())?;
        let mut response = Vec::new();
        BufReader::new(stream.take(2_800_001)).read_until(b'\n', &mut response).await.map_err(|e|e.to_string())?;
        if response.last()!=Some(&b'\n') || response.len()>2_800_000 { return Err("Tree response too large".into()) }
        verified_reply(&self.token,&nonce,&response)
    }
    pub(super) async fn start(&mut self, adapter: &mut AdapterHandle, rsd: &mut RsdHandshake) -> Result<(), String> {
        if self.task.as_ref().is_some_and(|t|!t.is_finished()) {return Ok(())}
        self.close().await;
        let mut proxy=bounded("tree_inventory",8,InstallationProxyClient::connect_rsd(adapter,rsd)).await?;
        let mut config=bounded("tree_companion",8,TestConfig::from_installation_proxy(&mut proxy,&format!("{}.tree.xctrunner", self.bundle_prefix),None)).await?;
        self.token=format!("{}{}",uuid::Uuid::new_v4().simple(),uuid::Uuid::new_v4().simple());
        let mut environment=plist::Dictionary::new();
        environment.insert("SOLOUSE_TREE_TOKEN".into(),self.token.clone().into());
        config.runner_env=Some(environment);
        let version=rsd.properties.get("OSVersion").or_else(||rsd.properties.get("ProductVersion")).and_then(plist::Value::as_string)
            .and_then(|v|v.split('.').next()?.parse::<u8>().ok()).ok_or("Missing device OS version")?;
        let mut runner_adapter=adapter.clone();
        let handshake=rsd.clone();
        self.task=Some(tokio::spawn(async move {
            run_on_rsd(config,version,&mut runner_adapter,&handshake,&mut Listener,None).await.map_err(|e|e.to_string())
        }));
        let deadline=Instant::now()+Duration::from_secs(35);
        loop {
            if self.task.as_ref().is_some_and(|t|t.is_finished()) {
                let task=self.task.take().unwrap();
                let result=task.await.map_err(|e|e.to_string())?;
                return Err(result.err().unwrap_or_else(||"Tree companion ended before readiness".into()))
            }
            if let Ok(Ok(reply))=tokio::time::timeout(Duration::from_millis(400),self.request("status")).await {
                if reply["status"]=="ready" && reply["protocol"]==2 {return Ok(())}
            }
            if CANCEL.load(Ordering::Acquire) || Instant::now()>=deadline {
                self.close().await;
                return Err("Tree companion startup did not complete".into())
            }
            tokio::time::sleep(Duration::from_millis(150)).await;
        }
    }
    pub(super) async fn read(&mut self, adapter: &mut AdapterHandle, rsd: &mut RsdHandshake) -> Value {
        let started=Instant::now();
        let result:Result<Value,String>=async {
            self.start(adapter,rsd).await?;
            let result=bounded("tree_snapshot",8,self.request("tree")).await?;
            if !result.is_object() || !matches!(result["status"].as_str(),Some("available"|"unavailable")) {
                return Err("Invalid tree status".into())
            }
            Ok(result)
        }.await;
        let mut result=match result {
            Ok(value)=>value,
            Err(error)=>{
                event("tree_error",json!({"message":error}));
                self.close().await;
                json!({"status":"unavailable","reason":"companion_unavailable","fallback":"Use the screenshot; an unavailable tree is not an empty screen."})
            }
        };
        result["elapsed_ms"]=json!(started.elapsed().as_millis() as u64);
        result
    }
    pub(super) async fn close(&mut self) {
        if let Some(task)=self.task.take() {
            let _=tokio::time::timeout(Duration::from_secs(1),self.request("stop")).await;
            task.abort();
            let _=task.await;
        }
        self.token.clear();
    }
}
impl Drop for TreeSession { fn drop(&mut self) {if let Some(task)=self.task.take(){task.abort()}} }

pub(super) async fn probe(c:&Config)->Result<(),String> {
    let (mut adapter,mut rsd)=connect(c).await?;
    let mut session=TreeSession::new(&c.bundle_prefix);
    let tree=session.read(&mut adapter,&mut rsd).await;
    private_write(&c.directory.join("tree-probe.json"),&serde_json::to_vec_pretty(&tree).map_err(|e|e.to_string())?)?;
    event("tree_probe",json!({"status":tree["status"],"node_count":tree["node_count"],"elapsed_ms":tree["elapsed_ms"]}));
    session.close().await;
    let _=tokio::time::timeout(Duration::from_secs(3),adapter.close()).await;
    if tree["status"]=="available" {Ok(())}else{Err("Tree snapshot unavailable; see diagnostic event".into())}
}

/// Developer fixture: opens only the existing Lab and LocalDevVPN apps, reads
/// their real trees/screens, then returns to SoloUse. No UI input or model calls.
pub(super) async fn fixture(c:&Config)->Result<(),String> {
    let (mut adapter,mut rsd)=connect(c).await?;
    let mut session=TreeSession::new(&c.bundle_prefix);
    let outcome=async {
        session.start(&mut adapter,&mut rsd).await?;
        let mut trials=Vec::new();
        for (name,app_id) in [("lab",format!("{}.lab",c.bundle_prefix)),("third_party","com.jkcoxson.LocalDevVPN".to_string()),("solouse",format!("{}.probe",c.bundle_prefix))] {
            if CANCEL.load(Ordering::Acquire){return Err("Cancelled".into())}
            let mut app=bounded("tree_fixture_app",5,AppServiceClient::connect_rsd(&mut adapter,&mut rsd)).await?;
            bounded("tree_fixture_open",5,app.launch_application(&app_id,&[],false,false,None,None,None)).await?;
            tokio::time::sleep(Duration::from_millis(500)).await;
            let mut samples=Vec::new();
            for _ in 0..3 {
                let tree=session.read(&mut adapter,&mut rsd).await;
                samples.push(tree);
            }
            let image= format!("tree-fixture-{name}.png");
            screenshot(c,&mut adapter,&mut rsd,&image).await?;
            trials.push(json!({"fixture":name,"expected_app":app_id,"samples":samples}));
        }
        private_write(&c.directory.join("tree-fixture.json"),&serde_json::to_vec_pretty(&json!({"trials":trials})).map_err(|e|e.to_string())?)?;
        Ok::<(),String>(())
    }.await;
    session.close().await;
    let _=tokio::time::timeout(Duration::from_secs(3),adapter.close()).await;
    outcome
}

fn signature(key:&str,message:&str)->String {
    let mut mac=Hmac::<Sha256>::new_from_slice(key.as_bytes()).expect("HMAC accepts any key length");
    mac.update(message.as_bytes());B64.encode(mac.finalize().into_bytes())
}
fn verified_reply(key:&str,nonce:&str,bytes:&[u8])->Result<Value,String> {
    let envelope:Value=serde_json::from_slice(bytes).map_err(|_|"Invalid tree envelope")?;
    if envelope["nonce"]!=nonce {return Err("Tree response nonce mismatch".into())}
    let payload=envelope["payload"].as_str().ok_or("Missing tree payload")?;
    let auth=envelope["mac"].as_str().ok_or("Missing tree authenticator")?;
    let auth=B64.decode(auth).map_err(|_|"Invalid tree authenticator")?;
    let mut mac=Hmac::<Sha256>::new_from_slice(key.as_bytes()).map_err(|_|"Invalid session key")?;
    mac.update(format!("response\n{nonce}\n{payload}").as_bytes());
    mac.verify_slice(&auth).map_err(|_|"Tree response authentication failed")?;
    let decoded=B64.decode(payload).map_err(|_|"Invalid tree payload")?;
    if decoded.len()>2_000_000{return Err("Tree payload too large".into())}
    serde_json::from_slice(&decoded).map_err(|_|"Invalid tree JSON".into())
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn authenticates_response_and_rejects_impostor_or_replay() {
        assert_eq!(signature(&"0".repeat(64),&format!("request\n{}\nstatus","1".repeat(32))),"MTcyhmu5//SVhycQ3yfmyc04vwobW5PiLfPlxwlEYok=");
        let key="0123456789abcdef0123456789abcdef";
        let nonce="fedcba9876543210fedcba9876543210";
        let payload=B64.encode(br#"{"status":"ready","protocol":1}"#);
        let valid=json!({"nonce":nonce,"payload":payload,"mac":signature(key,&format!("response\n{nonce}\n{payload}"))});
        let wire=serde_json::to_vec(&valid).unwrap();
        assert_eq!(verified_reply(key,nonce,&wire).unwrap()["status"],"ready");
        assert!(verified_reply("impostor",nonce,&wire).is_err());
        assert!(verified_reply(key,"different_nonce",&wire).is_err());
        let mut tampered=valid;tampered["payload"]=json!(B64.encode(br#"{"status":"available"}"#));
        assert!(verified_reply(key,nonce,&serde_json::to_vec(&tampered).unwrap()).is_err());
    }
}
