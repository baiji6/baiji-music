//! C ABI wrapper around baka-ac4-core v0.2.2 (Dolby AC-4 decoder).
//!
//! Mirrors the project's existing `*_glue` ABI so the Dart side can reuse its
//! proven dart:ffi + isolate + HTTP stream playback pipeline:
//!
//!   void*  ac4baka_init(void);
//!   int    ac4baka_open(void* h, const char* path);   // demux mp4/raw ac4
//!   int    ac4baka_info(void* h, int* rate, int* ch, int* frames);
//!   int    ac4baka_decode_to_wav(void* h, const char* wav,
//!                               void (*progress)(long, void*), void* user);
//!   void   ac4baka_close(void* h);
//!   const char* ac4baka_last_error(void);
//!
//! A-JOC streams are rendered to stereo via `set_ajoc_render(Stereo)`; channel
//! coded streams keep their native layout. Output is 16-bit PCM WAV.

use baka_ac4_cli::{mp4, raw};
use baka_ac4_core::{
    ajoc::render::{RenderOptions, SpeakerLayout},
    Ac4Decoder, AudioKind,
};
use std::{
    cell::RefCell,
    ffi::{CStr, CString},
    fs::File,
    io::{BufWriter, Seek, SeekFrom, Write},
    os::raw::{c_char, c_int, c_long, c_void},
    ptr,
};

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_err(msg: &str) {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    LAST_ERROR.with(|e| *e.borrow_mut() = c);
}

struct Ac4Ctx {
    data: Vec<u8>,
    samples: Vec<(u64, u32)>,
    codec: String,
    channels: u16,
    sample_rate: u32,
}

#[no_mangle]
pub extern "C" fn ac4baka_init() -> *mut c_void {
    Box::into_raw(Box::new(None::<Ac4Ctx>)) as *mut c_void
}

unsafe fn ctx_ptr<'a>(h: *mut c_void) -> &'a mut Option<Ac4Ctx> {
    &mut *(h as *mut Option<Ac4Ctx>)
}

#[no_mangle]
pub unsafe extern "C" fn ac4baka_open(h: *mut c_void, path: *const c_char) -> c_int {
    if h.is_null() || path.is_null() {
        set_err("null argument");
        return -1;
    }
    let p = match CStr::from_ptr(path).to_str() {
        Ok(s) => s,
        Err(_) => {
            set_err("invalid utf-8 path");
            return -1;
        }
    };
    let data = match std::fs::read(p) {
        Ok(d) => d,
        Err(e) => {
            set_err(&format!("read failed: {e}"));
            return -1;
        }
    };
    let track = if raw::is_raw_ac4(&data) {
        match raw::read_ac4_frames(&data) {
            Ok(t) => t,
            Err(e) => {
                set_err(&e);
                return -1;
            }
        }
    } else {
        match mp4::read_ac4_track(&data) {
            Ok(t) => t,
            Err(e) => {
                set_err(&e);
                return -1;
            }
        }
    };
    *ctx_ptr(h) = Some(Ac4Ctx {
        data,
        samples: track.samples,
        codec: track.codec,
        channels: track.channels,
        sample_rate: track.sample_rate,
    });
    0
}

#[no_mangle]
pub unsafe extern "C" fn ac4baka_info(
    h: *mut c_void,
    rate: *mut c_int,
    ch: *mut c_int,
    frames: *mut c_int,
) -> c_int {
    if h.is_null() {
        set_err("null handle");
        return -1;
    }
    let ctx = match ctx_ptr(h).as_ref() {
        Some(c) => c,
        None => {
            set_err("not opened");
            return -1;
        }
    };
    // A-JOC renders to stereo; channel-coded streams keep native channels.
    // The real output rate/layout is discovered on the first decoded frame;
    // here we expose the container header values as a hint.
    if !rate.is_null() {
        *rate = ctx.sample_rate as c_int;
    }
    if !ch.is_null() {
        *ch = if ctx.channels == 0 { 2 } else { ctx.channels as c_int };
    }
    if !frames.is_null() {
        *frames = ctx.samples.len() as c_int;
    }
    0
}

/// Write a 16-bit PCM WAV header. `data_bytes = 0xFFFFFFFF` means "unknown
/// total length" (streaming mode); the header is then never rewritten.
fn wav_header(rate: u32, channels: u16, data_bytes: u32) -> [u8; 44] {
    let mut h = [0u8; 44];
    h[..4].copy_from_slice(b"RIFF");
    if data_bytes == u32::MAX {
        h[4..8].copy_from_slice(&u32::MAX.to_le_bytes());
    } else {
        h[4..8].copy_from_slice(&(36u32.wrapping_add(data_bytes)).to_le_bytes());
    }
    h[8..16].copy_from_slice(b"WAVEfmt ");
    h[16..20].copy_from_slice(&16u32.to_le_bytes());
    h[20..22].copy_from_slice(&1u16.to_le_bytes()); // PCM
    h[22..24].copy_from_slice(&channels.to_le_bytes());
    h[24..28].copy_from_slice(&rate.to_le_bytes());
    h[28..32].copy_from_slice(&(rate * u32::from(channels) * 2).to_le_bytes());
    h[32..34].copy_from_slice(&(channels * 2).to_le_bytes());
    h[34..36].copy_from_slice(&16u16.to_le_bytes());
    h[36..40].copy_from_slice(b"data");
    h[40..44].copy_from_slice(&data_bytes.to_le_bytes());
    h
}

/// `stream_mode = true` writes an unknown-length header up front and never
/// seeks back (safe for a tail-and-push reader). `false` writes a normal header
/// and back-fills the real size at finish (for a cached whole-file WAV).
unsafe fn decode_impl(
    h: *mut c_void,
    wav: *const c_char,
    progress: Option<unsafe extern "C" fn(c_long, *mut c_void)>,
    user: *mut c_void,
    stream_mode: bool,
) -> c_int {
    if h.is_null() || wav.is_null() {
        set_err("null argument");
        return -1;
    }
    let ctx = match ctx_ptr(h).as_ref() {
        Some(c) => c,
        None => {
            set_err("not opened");
            return -1;
        }
    };
    let wav_path = match CStr::from_ptr(wav).to_str() {
        Ok(s) => s,
        Err(_) => {
            set_err("invalid utf-8 wav path");
            return -1;
        }
    };

    let mut dec = match Ac4Decoder::new() {
        Ok(d) => d,
        Err(e) => {
            set_err(&format!("decoder init: {e}"));
            return -1;
        }
    };
    // Render A-JOC object streams down to stereo for playback.
    let _ = dec.set_ajoc_render(Some(RenderOptions::new(SpeakerLayout::Stereo)));

    let f = match File::create(wav_path) {
        Ok(f) => f,
        Err(e) => {
            set_err(&format!("create wav: {e}"));
            return -1;
        }
    };
    let mut out = BufWriter::new(f);
    // Streaming: unknown-length header up front, never rewritten. Whole-file:
    // placeholder header rewritten at finish.
    let init_data = if stream_mode { u32::MAX } else { 0 };
    if out.write_all(&wav_header(48000, 2, init_data)).is_err() {
        set_err("write wav header");
        return -1;
    }

    let total = ctx.samples.len();
    let mut rate = 48000u32;
    let mut channels = 2u16;
    let mut data_bytes: u64 = 0;
    let mut pcm: Vec<Vec<f32>> = Vec::new();
    let mut done = 0usize;

    for &(off, size) in &ctx.samples {
        let end = off as usize + size as usize;
        if end > ctx.data.len() {
            set_err("sample out of range");
            return -1;
        }
        let pkt = &ctx.data[off as usize..end];
        let info = match dec.decode_frame_into(pkt, &mut pcm) {
            Ok(Some(i)) => i,
            Ok(None) => {
                done += 1;
                continue;
            }
            Err(e) => {
                set_err(&format!("decode frame {done}: {e}"));
                return -1;
            }
        };
        // Keep only speaker-feed / channel output with finite samples.
        if info.audio_kind == AudioKind::AjocObjectSignals
            || info.audio_kind == AudioKind::AjocCoreSignals
        {
            done += 1;
            continue;
        }
        if pcm.is_empty() || pcm.iter().any(|c| c.len() != info.nb_samples) {
            done += 1;
            continue;
        }
        rate = info.sample_rate;
        channels = pcm.len() as u16;
        let n = info.nb_samples;
        for i in 0..n {
            for c in &pcm {
                let v = (c[i] * 32768.0).round().clamp(-32768.0, 32767.0) as i16;
                if out.write_all(&v.to_le_bytes()).is_err() {
                    set_err("write pcm");
                    return -1;
                }
            }
        }
        data_bytes += (n as u64) * (channels as u64) * 2;
        done += 1;
        if let Some(cb) = progress {
            cb(done as c_long, user);
        }
    }

    // Streaming mode never seeks back: the header stays unknown-length.
    // Whole-file mode back-fills the real format/size.
    if !stream_mode {
        if out.seek(SeekFrom::Start(0)).is_err()
            || out.write_all(&wav_header(rate, channels, data_bytes as u32)).is_err()
        {
            set_err("finalize wav");
            return -1;
        }
    }
    if out.flush().is_err() {
        set_err("flush wav");
        return -1;
    }
    let _ = total;
    0
}

#[no_mangle]
pub unsafe extern "C" fn ac4baka_decode_to_wav(
    h: *mut c_void,
    wav: *const c_char,
    progress: Option<unsafe extern "C" fn(c_long, *mut c_void)>,
    user: *mut c_void,
) -> c_int {
    decode_impl(h, wav, progress, user, false)
}

#[no_mangle]
pub unsafe extern "C" fn ac4baka_decode_to_stream(
    h: *mut c_void,
    wav: *const c_char,
    progress: Option<unsafe extern "C" fn(c_long, *mut c_void)>,
    user: *mut c_void,
) -> c_int {
    decode_impl(h, wav, progress, user, true)
}

#[no_mangle]
pub unsafe extern "C" fn ac4baka_close(h: *mut c_void) {
    if h.is_null() {
        return;
    }
    *ctx_ptr(h) = None;
    drop(Box::from_raw(h as *mut Option<Ac4Ctx>));
}

#[no_mangle]
pub extern "C" fn ac4baka_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}
