use std::sync::{Arc, RwLock};

use gpapi::{
  service::request::UpdateGuiRequest,
  utils::{checksum::verify_checksum, crypto::Crypto, endpoint::http_endpoint},
};
use log::{info, warn};
use tauri::{Emitter, WebviewWindow};

use crate::downloader::{ChecksumFetcher, FileDownloader};

#[cfg(not(debug_assertions))]
const SNAPSHOT: &str = match option_env!("SNAPSHOT") {
  Some(val) => val,
  None => "false",
};

pub struct ProgressNotifier {
  win: WebviewWindow,
}

impl ProgressNotifier {
  pub fn new(win: WebviewWindow) -> Self {
    Self { win }
  }

  fn notify(&self, progress: Option<f64>) {
    let _ = self.win.emit("app://update-progress", progress);
  }

  fn notify_error(&self) {
    let _ = self.win.emit("app://update-error", ());
  }

  fn notify_done(&self) {
    let _ = self.win.emit("app://update-done", ());
  }
}

pub struct Installer {
  crypto: Crypto,
}

impl Installer {
  pub fn new(api_key: Vec<u8>) -> Self {
    Self {
      crypto: Crypto::new(api_key),
    }
  }

  async fn install(&self, path: &str, checksum: &str) -> anyhow::Result<()> {
    let service_endpoint = http_endpoint().await?;

    let request = UpdateGuiRequest {
      path: path.to_string(),
      checksum: checksum.to_string(),
    };
    let payload = self.crypto.encrypt(&request)?;

    reqwest::Client::default()
      .post(format!("{}/update-gui", service_endpoint))
      .body(payload)
      .send()
      .await?
      .error_for_status()?;

    Ok(())
  }
}

pub struct GuiUpdater {
  version: String,
  notifier: Arc<ProgressNotifier>,
  installer: Installer,
  in_progress: RwLock<bool>,
  progress: Arc<RwLock<Option<f64>>>,
}

impl GuiUpdater {
  pub fn new(version: String, notifier: ProgressNotifier, installer: Installer) -> Self {
    Self {
      version,
      notifier: Arc::new(notifier),
      installer,
      in_progress: Default::default(),
      progress: Default::default(),
    }
  }

  pub async fn update(&self) {
    info!("Update GUI, version: {}", self.version);

    #[cfg(debug_assertions)]
    let release_tag = "snapshot";
    #[cfg(not(debug_assertions))]
    let release_tag = if SNAPSHOT == "true" {
      String::from("snapshot")
    } else {
      format!("v{}", self.version)
    };

    #[cfg(target_arch = "x86_64")]
    let arch = "x86_64";
    #[cfg(target_arch = "aarch64")]
    let arch = "aarch64";

    let file_url = format!(
      "https://github.com/yuezk/GlobalProtect-openconnect/releases/download/{}/gpgui_{}.bin.tar.xz",
      release_tag, arch
    );
    let checksum_url = format!("{}.sha256", file_url);

    info!("Downloading file: {}", file_url);

    let dl = FileDownloader::new(&file_url);
    let cf = ChecksumFetcher::new(&checksum_url);
    let notifier = Arc::clone(&self.notifier);

    let progress_ref = Arc::clone(&self.progress);
    dl.on_progress(move |progress| {
      // Save progress to shared state so that it can be notified to the UI when needed
      if let Ok(mut guard) = progress_ref.try_write() {
        *guard = progress;
      }
      notifier.notify(progress);
    });

    self.set_in_progress(true);
    let res = tokio::try_join!(dl.download(), cf.fetch());

    let (file, checksum) = match res {
      Ok((file, checksum)) => (file, checksum),
      Err(err) => {
        warn!("Download error: {}", err);
        self.notify_error();
        return;
      }
    };

    let path = file.into_temp_path();
    let file_path = path.to_string_lossy();

    if let Err(err) = verify_checksum(&file_path, &checksum) {
      warn!("Checksum error: {}", err);
      self.notify_error();
      return;
    }

    info!("Checksum success");

    if let Err(err) = self.installer.install(&file_path, &checksum).await {
      warn!("Install error: {}", err);
      self.notify_error();
    } else {
      info!("Install success");
      self.notify_done();
    }
  }

  pub fn is_in_progress(&self) -> bool {
    if let Ok(guard) = self.in_progress.try_read() {
      *guard
    } else {
      info!("Failed to acquire in_progress lock");
      false
    }
  }

  fn set_in_progress(&self, in_progress: bool) {
    if let Ok(mut guard) = self.in_progress.try_write() {
      *guard = in_progress;
    } else {
      info!("Failed to acquire in_progress lock");
    }
  }

  fn notify_error(&self) {
    self.set_in_progress(false);
    self.notifier.notify_error();
  }

  fn notify_done(&self) {
    self.set_in_progress(false);
    self.notifier.notify_done();
  }

  pub fn notify_progress(&self) {
    let progress = if let Ok(guard) = self.progress.try_read() {
      *guard
    } else {
      info!("Failed to acquire progress lock");
      None
    };

    self.notifier.notify(progress);
  }
}
