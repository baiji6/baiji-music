//! C ABI wrapper around baka-av3a-core/container v0.1.2 (Audio Vivid / AV3A).
//!
//!   void*  av3abaka_init(void);
//!   int    av3abaka_open(void* h, const char* path,
//!                        const char* model_path, const char* lsf_path,
//!                        const char* mcr_path_or_null, const char* hoa_path_or_null);
//!   int    av3abaka_info(void* h, int* rate, int* ch, int* frames);
//!   int    av3abaka_decode_to_wav(void* h, const char* wav,
//!                                void (*progress)(long, void*), void* user);
//!   void   av3abaka_close(void* h);
//!   const char* av3abaka_last_error(void);
//!
//! Model / LSF / MCR / HOA assets are caller supplied (bundled in app assets).

use baka_av3a_container::Track;
use baka_av3a_core::{
    decoder::Decoder, hoa::HoaBasis, mcr::McrCodebooks, model::HyperModel,
    shaping::LsfCodebooks, FrameHeader,
};
use std::{
    cell::RefCell,
    ffi::{CStr, CString},
    fs::File,
    io::{BufWriter, Seek, SeekFrom, Write},
    os::raw::{c_char, c_int, c_long, c_void},
    ptr,
    sync::Arc,
};

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_err(msg: &str) {
    let c = CString::new(msg).unwrap_or_else(|_| CString::new("error").unwrap());
    LAST_ERROR.with(|e| *e.borrow_mut() = c);
}

struct Av3aCtx {
    data: Vec<u8>,
    model: Vec<u8>,
    lsf: Vec<u8>,
    mcr: Option<Vec<u8>>,
    hoa: Option<Vec<u8>>,
    rate: u32,
    channels: u16,
    packets: usize,
}

#[no_mangle]
pub extern "C" fn av3abaka_init() -> *mut c_void {
    Box::into_raw(Box::new(None::<Av3aCtx>)) as *mut c_void
}

unsafe fn ctx_ptr<'a>(h: *mut c_void) -> &'a mut Option<Av3aCtx> {
    &mut *(h as *mut Option<Av3aCtx>)
}

unsafe fn opt_read(p: *const c_char) -> Option<Vec<u8>> {
    if p.is_null() {
        return None;
    }
    let s = CStr::from_ptr(p).to_str().ok()?;
    std::fs::read(s).ok()
}

#[no_mangle]
pub unsafe extern "C" fn av3abaka_open(
    h: *mut c_void,
    path: *const c_char,
    model_path: *const c_char,
    lsf_path: *const c_char,
    mcr_path: *const c_char,
    hoa_path: *const c_char,
) -> c_int {
    if h.is_null() || path.is_null() || model_path.is_null() || lsf_path.is_null() {
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
    let model = match opt_read(model_path) {
        Some(v) => v,
        None => {
            set_err("cannot read model asset");
            return -1;
        }
    };
    let lsf = match opt_read(lsf_path) {
        Some(v) => v,
        None => {
            set_err("cannot read lsf asset");
            return -1;
        }
    };
    let (rate, channels, packets) = {
        let track = match Track::parse(&data) {
            Ok(t) => t,
            Err(e) => {
                set_err(&format!("not an av3a mp4: {e}"));
                return -1;
            }
        };
        let header = match track.validate_frames() {
            Ok(h) => h,
            Err(e) => {
                set_err(&format!("invalid av3a frames: {e}"));
                return -1;
            }
        };
        (header.sample_rate, header.channels, track.packet_count())
    };
    *ctx_ptr(h) = Some(Av3aCtx {
        data,
        model,
        lsf,
        mcr: opt_read(mcr_path),
        hoa: opt_read(hoa_path),
        rate,
        channels,
        packets,
    });
    0
}

#[no_mangle]
pub unsafe extern "C" fn av3abaka_info(
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
    if !rate.is_null() {
        *rate = ctx.rate as c_int;
    }
    if !ch.is_null() {
        *ch = ctx.channels as c_int;
    }
    if !frames.is_null() {
        *frames = ctx.packets as c_int;
    }
    0
}

fn header_bytes(rate: u32, channels: u16, bytes: u32) -> [u8; 44] {
    let mut h = [0u8; 44];
    h[..4].copy_from_slice(b"RIFF");
    if bytes == u32::MAX {
        h[4..8].copy_from_slice(&u32::MAX.to_le_bytes());
    } else {
        h[4..8].copy_from_slice(&(36u32.wrapping_add(bytes)).to_le_bytes());
    }
    h[8..16].copy_from_slice(b"WAVEfmt ");
    h[16..20].copy_from_slice(&16u32.to_le_bytes());
    h[20..22].copy_from_slice(&1u16.to_le_bytes());
    h[22..24].copy_from_slice(&channels.to_le_bytes());
    h[24..28].copy_from_slice(&rate.to_le_bytes());
    h[28..32].copy_from_slice(&(rate * u32::from(channels) * 2).to_le_bytes());
    h[32..34].copy_from_slice(&(channels * 2).to_le_bytes());
    h[34..36].copy_from_slice(&16u16.to_le_bytes());
    h[36..40].copy_from_slice(b"data");
    h[40..44].copy_from_slice(&bytes.to_le_bytes());
    h
}

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

    let mut decoder = Decoder::new(
        match HyperModel::parse(&ctx.model) {
            Ok(m) => Arc::new(m),
            Err(e) => {
                set_err(&format!("parse model: {e}"));
                return -1;
            }
        },
        match LsfCodebooks::parse(&ctx.lsf) {
            Ok(l) => Arc::new(l),
            Err(e) => {
                set_err(&format!("parse lsf: {e}"));
                return -1;
            }
        },
    );
    if let Some(ref m) = ctx.mcr {
        if let Ok(cb) = McrCodebooks::parse(m) {
            decoder = decoder.with_mcr(Arc::new(cb));
        }
    }
    if let Some(ref hb) = ctx.hoa {
        if let Ok(b) = HoaBasis::parse(hb) {
            decoder = decoder.with_hoa(Arc::new(b));
        }
    }

    let track = match Track::parse(&ctx.data) {
        Ok(t) => t,
        Err(e) => {
            set_err(&format!("parse track: {e}"));
            return -1;
        }
    };
    let header = match track.validate_frames() {
        Ok(h) => h,
        Err(e) => {
            set_err(&format!("validate frames: {e}"));
            return -1;
        }
    };

    // Validate all CRCs before writing output.
    for packet in track.packets() {
        if let Err(e) = FrameHeader::validate_crc(packet.bytes) {
            set_err(&format!("crc: {e}"));
            return -1;
        }
    }

    let f = match File::create(wav_path) {
        Ok(f) => f,
        Err(e) => {
            set_err(&format!("create wav: {e}"));
            return -1;
        }
    };
    let mut out = BufWriter::new(f);
    let rate = header.sample_rate;
    let channels = header.channels;
    let init_bytes = if stream_mode { u32::MAX } else { 0 };
    if out.write_all(&header_bytes(rate, channels, init_bytes)).is_err() {
        set_err("write header");
        return -1;
    }
    let mut data_bytes: u64 = 0;
    let mut done = 0usize;
    let total = track.packet_count();

    for packet in track.packets() {
        let frame = match decoder.decode(packet.bytes) {
            Ok(f) => f,
            Err(e) => {
                set_err(&format!("decode packet {done}: {e}"));
                return -1;
            }
        };
        for v in frame.to_i16() {
            if out.write_all(&v.to_le_bytes()).is_err() {
                set_err("write pcm");
                return -1;
            }
        }
        data_bytes += (frame.samples.len() as u64) * 2;
        done += 1;
        if let Some(cb) = progress {
            cb(done as c_long, user);
        }
    }
    let _ = total;

    if !stream_mode {
        if out.seek(SeekFrom::Start(0)).is_err()
            || out.write_all(&header_bytes(rate, channels, data_bytes as u32)).is_err()
        {
            set_err("finalize wav");
            return -1;
        }
    }
    if out.flush().is_err() {
        set_err("flush wav");
        return -1;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn av3abaka_decode_to_wav(
    h: *mut c_void,
    wav: *const c_char,
    progress: Option<unsafe extern "C" fn(c_long, *mut c_void)>,
    user: *mut c_void,
) -> c_int {
    decode_impl(h, wav, progress, user, false)
}

#[no_mangle]
pub unsafe extern "C" fn av3abaka_decode_to_stream(
    h: *mut c_void,
    wav: *const c_char,
    progress: Option<unsafe extern "C" fn(c_long, *mut c_void)>,
    user: *mut c_void,
) -> c_int {
    decode_impl(h, wav, progress, user, true)
}

#[no_mangle]
pub unsafe extern "C" fn av3abaka_close(h: *mut c_void) {
    if h.is_null() {
        return;
    }
    *ctx_ptr(h) = None;
    drop(Box::from_raw(h as *mut Option<Av3aCtx>));
}

#[no_mangle]
pub extern "C" fn av3abaka_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}
