use super::{Cursor, CustomEvent};
use crate::{
    ipc::{self, Data},
    CHILD_PROCESS,
};
use camellia_remote_protocol::{
    allow_err,
    anyhow::anyhow,
    bail, log, sleep,
    tokio::{
        self,
        sync::{
            mpsc::{channel, error::TrySendError, Sender},
            watch,
        },
        time::{interval_at, timeout},
    },
    ResultType,
};
use lazy_static::lazy_static;
use std::{
    collections::HashMap,
    sync::{Mutex, RwLock},
    time::{Duration, Instant},
};

type WhiteboardEvent = (String, CustomEvent);

const WHITEBOARD_EVENT_CAPACITY: usize = 256;
const CURSOR_FLUSH_INTERVAL: Duration = Duration::from_millis(33);

lazy_static! {
    static ref WHITEBOARD_WORKER: Mutex<WhiteboardWorkerState> = Default::default();
    static ref CONNS: RwLock<HashMap<String, Conn>> = Default::default();
}

enum WhiteboardWorkerPhase {
    Stopped,
    Starting {
        generation: u64,
    },
    Running {
        generation: u64,
        events: Sender<WhiteboardEvent>,
        stop: watch::Sender<bool>,
    },
}

struct WhiteboardWorkerState {
    next_generation: u64,
    phase: WhiteboardWorkerPhase,
}

impl Default for WhiteboardWorkerState {
    fn default() -> Self {
        Self {
            next_generation: 0,
            phase: WhiteboardWorkerPhase::Stopped,
        }
    }
}

impl WhiteboardWorkerState {
    fn begin_start(&mut self) -> Option<u64> {
        if !matches!(self.phase, WhiteboardWorkerPhase::Stopped) {
            return None;
        }
        self.next_generation = self.next_generation.checked_add(1).unwrap_or(1);
        let generation = self.next_generation;
        self.phase = WhiteboardWorkerPhase::Starting { generation };
        Some(generation)
    }

    fn is_current(&self, generation: u64) -> bool {
        matches!(
            self.phase,
            WhiteboardWorkerPhase::Starting {
                generation: current
            } | WhiteboardWorkerPhase::Running {
                generation: current,
                ..
            } if current == generation
        )
    }

    fn publish(
        &mut self,
        generation: u64,
        events: Sender<WhiteboardEvent>,
        stop: watch::Sender<bool>,
    ) -> bool {
        if !matches!(
            self.phase,
            WhiteboardWorkerPhase::Starting {
                generation: current
            } if current == generation
        ) {
            return false;
        }
        self.phase = WhiteboardWorkerPhase::Running {
            generation,
            events,
            stop,
        };
        true
    }

    fn event_sender(&self) -> Option<Sender<WhiteboardEvent>> {
        match &self.phase {
            WhiteboardWorkerPhase::Running { events, .. } => Some(events.clone()),
            _ => None,
        }
    }

    fn stop(&mut self) -> Option<watch::Sender<bool>> {
        match std::mem::replace(&mut self.phase, WhiteboardWorkerPhase::Stopped) {
            WhiteboardWorkerPhase::Running { stop, .. } => Some(stop),
            _ => None,
        }
    }

    fn finish(&mut self, generation: u64) {
        if self.is_current(generation) {
            self.phase = WhiteboardWorkerPhase::Stopped;
        }
    }
}

struct Conn {
    last_cursor_pos: (f32, f32), // For click ripple
    last_cursor_evt: LastCursorEvent,
}

struct LastCursorEvent {
    evt: Option<CustomEvent>,
    tm: Instant,
}

#[inline]
pub fn get_key_cursor(conn_id: i32) -> String {
    format!("{}-cursor", conn_id)
}

pub fn register_whiteboard(k: String) {
    {
        let mut conns = CONNS.write().unwrap();
        conns.entry(k).or_insert_with(|| Conn {
            last_cursor_pos: (0.0, 0.0),
            last_cursor_evt: LastCursorEvent {
                evt: None,
                tm: Instant::now(),
            },
        });
    }
    ensure_whiteboard_started();
}

pub fn unregister_whiteboard(k: String) {
    let is_conns_empty = {
        let mut conns = CONNS.write().unwrap();
        conns.remove(&k);
        conns.is_empty()
    };
    if is_conns_empty {
        stop_whiteboard();
    } else {
        queue_whiteboard_event((k, CustomEvent::Clear));
    }
}

pub fn update_whiteboard(k: String, e: CustomEvent) {
    let events = {
        let mut conns = CONNS.write().unwrap();
        let Some(conn) = conns.get_mut(&k) else {
            return;
        };
        match &e {
            CustomEvent::Cursor(cursor) if cursor.btns == 0 => {
                conn.last_cursor_pos = (cursor.x, cursor.y);
                conn.last_cursor_evt.evt = Some(e);
                conn.last_cursor_evt.tm = Instant::now();
                Vec::new()
            }
            CustomEvent::Cursor(cursor) => {
                let mut events = Vec::with_capacity(2);
                if let Some(evt) = conn.last_cursor_evt.evt.take() {
                    events.push((k.clone(), evt));
                }
                let click_evt = CustomEvent::Cursor(Cursor {
                    x: conn.last_cursor_pos.0,
                    y: conn.last_cursor_pos.1,
                    argb: cursor.argb,
                    btns: cursor.btns,
                    text: cursor.text.clone(),
                });
                events.push((k, click_evt));
                events
            }
            _ => vec![(k, e)],
        }
    };
    for event in events {
        queue_whiteboard_event(event);
    }
}

fn ensure_whiteboard_started() {
    let generation = {
        let conns = CONNS.read().unwrap();
        if conns.is_empty() {
            return;
        }
        WHITEBOARD_WORKER.lock().unwrap().begin_start()
    };
    let Some(generation) = generation else {
        return;
    };
    let Ok(runtime) = tokio::runtime::Handle::try_current() else {
        WHITEBOARD_WORKER.lock().unwrap().finish(generation);
        log::error!("Cannot start whiteboard outside a Tokio runtime");
        return;
    };
    runtime.spawn(async move {
        if let Err(err) = start_whiteboard_(generation).await {
            log::error!("Whiteboard worker failed: {err}");
        }
        WHITEBOARD_WORKER.lock().unwrap().finish(generation);
    });
}

fn stop_whiteboard() {
    let stop = {
        let conns = CONNS.read().unwrap();
        if !conns.is_empty() {
            return;
        }
        WHITEBOARD_WORKER.lock().unwrap().stop()
    };
    if let Some(stop) = stop {
        let _ = stop.send(true);
    }
}

fn queue_whiteboard_event(event: WhiteboardEvent) {
    let sender = WHITEBOARD_WORKER.lock().unwrap().event_sender();
    let Some(sender) = sender else {
        retain_cursor_event(event);
        return;
    };
    match sender.try_send(event) {
        Ok(()) => {}
        Err(TrySendError::Full(event)) | Err(TrySendError::Closed(event)) => {
            retain_cursor_event(event);
        }
    }
}

fn retain_cursor_event((k, event): WhiteboardEvent) {
    if !matches!(event, CustomEvent::Cursor(_)) {
        log::warn!("Whiteboard control event queue is full or closed");
        return;
    }
    if let Some(conn) = CONNS.write().unwrap().get_mut(&k) {
        conn.last_cursor_evt.evt = Some(event);
        conn.last_cursor_evt.tm = Instant::now();
    }
}

fn worker_is_current(generation: u64) -> bool {
    WHITEBOARD_WORKER.lock().unwrap().is_current(generation)
}

fn take_pending_cursor_events() -> Vec<WhiteboardEvent> {
    let mut conns = CONNS.write().unwrap();
    conns
        .iter_mut()
        .filter_map(|(k, conn)| {
            if conn.last_cursor_evt.tm.elapsed() < CURSOR_FLUSH_INTERVAL {
                return None;
            }
            conn.last_cursor_evt
                .evt
                .take()
                .map(|event| (k.clone(), event))
        })
        .collect()
}

async fn start_whiteboard_(generation: u64) -> ResultType<()> {
    loop {
        if !worker_is_current(generation) {
            return Ok(());
        }
        if !crate::platform::is_prelogin() {
            break;
        }
        sleep(1.).await;
    }
    let mut stream = None;
    if !worker_is_current(generation) {
        return Ok(());
    }
    if let Ok(s) = ipc::connect(1000, "_whiteboard").await {
        stream = Some(s);
    } else {
        #[allow(unused_mut)]
        #[allow(unused_assignments)]
        let mut args = vec!["--whiteboard"];
        #[allow(unused_mut)]
        #[cfg(target_os = "linux")]
        let mut user = None;

        let run_done;
        if crate::platform::is_root() {
            let mut res = Ok(None);
            for _ in 0..10 {
                if !worker_is_current(generation) {
                    return Ok(());
                }
                #[cfg(not(any(target_os = "linux")))]
                {
                    log::debug!("Start whiteboard");
                    res = crate::platform::run_as_user(args.clone());
                }
                #[cfg(target_os = "linux")]
                {
                    log::debug!("Start whiteboard");
                    res = crate::platform::run_as_user(
                        args.clone(),
                        user.clone(),
                        None::<(&str, &str)>,
                    );
                }
                if res.is_ok() {
                    break;
                }
                log::error!("Failed to run whiteboard: {res:?}");
                sleep(1.).await;
            }
            if let Some(task) = res? {
                CHILD_PROCESS.lock().unwrap().push(task);
            }
            run_done = true;
        } else {
            run_done = false;
        }
        if !run_done {
            log::debug!("Start whiteboard");
            CHILD_PROCESS.lock().unwrap().push(crate::run_me(args)?);
        }
        for _ in 0..20 {
            if !worker_is_current(generation) {
                return Ok(());
            }
            sleep(0.3).await;
            if let Ok(s) = ipc::connect(1000, "_whiteboard").await {
                stream = Some(s);
                break;
            }
        }
        if stream.is_none() {
            bail!("Failed to connect to connection manager");
        }
    }

    let mut stream = stream.ok_or(anyhow!("none stream"))?;
    let (events_tx, mut events_rx) = channel(WHITEBOARD_EVENT_CAPACITY);
    let (stop_tx, mut stop_rx) = watch::channel(false);
    let published = {
        let conns = CONNS.read().unwrap();
        !conns.is_empty()
            && WHITEBOARD_WORKER
                .lock()
                .unwrap()
                .publish(generation, events_tx, stop_tx)
    };
    if !published {
        let exit = Data::Whiteboard(("".to_string(), CustomEvent::Exit));
        let _ = timeout(Duration::from_secs(1), stream.send(&exit)).await;
        return Ok(());
    }

    let mut timer = interval_at(
        tokio::time::Instant::now() + CURSOR_FLUSH_INTERVAL,
        CURSOR_FLUSH_INTERVAL,
    );
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = stop_rx.changed() => {
                break;
            }
            res = events_rx.recv() => {
                match res {
                    Some(data) => {
                        if matches!(data.1, CustomEvent::Exit) {
                            break;
                        } else {
                            let data = Data::Whiteboard(data);
                            let send = stream.send(&data);
                            tokio::select! {
                                _ = stop_rx.changed() => break,
                                result = send => allow_err!(result),
                            }
                            timer.reset();
                        }
                    }
                    None => {
                        break;
                    }
                }
            },
            _ = timer.tick() => {
                for event in take_pending_cursor_events() {
                    let event = Data::Whiteboard(event);
                    let send = stream.send(&event);
                    tokio::select! {
                        _ = stop_rx.changed() => break,
                        result = send => allow_err!(result),
                    }
                }
            }
        }
    }
    let exit = Data::Whiteboard(("".to_string(), CustomEvent::Exit));
    let _ = timeout(Duration::from_secs(1), stream.send(&exit)).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_generation_allows_one_start_and_rejects_stale_completion() {
        let mut state = WhiteboardWorkerState::default();
        let first = state.begin_start().unwrap();
        assert!(state.begin_start().is_none());

        let (events, _events_rx) = channel(1);
        let (stop, mut stop_rx) = watch::channel(false);
        assert!(state.publish(first, events, stop));
        assert!(state.event_sender().is_some());
        state.stop().unwrap().send(true).unwrap();
        assert!(*stop_rx.borrow_and_update());

        let second = state.begin_start().unwrap();
        state.finish(first);
        assert!(state.is_current(second));
        assert!(!state.is_current(first));
    }

    #[test]
    fn worker_event_queue_has_a_hard_capacity() {
        let mut state = WhiteboardWorkerState::default();
        let generation = state.begin_start().unwrap();
        let (events, _events_rx) = channel(1);
        let (stop, _stop_rx) = watch::channel(false);
        assert!(state.publish(generation, events, stop));

        let sender = state.event_sender().unwrap();
        sender
            .try_send(("one".to_owned(), CustomEvent::Clear))
            .unwrap();
        assert!(matches!(
            sender.try_send(("two".to_owned(), CustomEvent::Clear)),
            Err(TrySendError::Full(_))
        ));
    }
}
