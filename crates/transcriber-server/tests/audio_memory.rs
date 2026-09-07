use std::alloc::{GlobalAlloc, Layout, System};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicUsize, Ordering};

#[allow(dead_code)]
#[path = "../src/audio.rs"]
mod audio;
use audio::pcm_to_wav;

// A separate integration-test binary isolates the allocation budget from other tests.
struct CountingAllocator;
static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

fn allocated(size: usize) {
    let live = LIVE.fetch_add(size, Ordering::Relaxed) + size;
    PEAK.fetch_max(live, Ordering::Relaxed);
}

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let pointer = unsafe { System.alloc(layout) };
        if !pointer.is_null() {
            allocated(layout.size());
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        unsafe { System.dealloc(pointer, layout) };
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let next = unsafe { System.realloc(pointer, layout, new_size) };
        if !next.is_null() {
            LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
            allocated(new_size);
        }
        next
    }
}

#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

#[test]
fn converts_pcm_with_only_the_output_and_bounded_scratch_memory() {
    let directory = tempfile::tempdir().unwrap();
    let partial = directory.path().join("capture.pcm.partial");
    let wav = directory.path().join("audio.wav");
    // Include fractional resampling, upsampling, and buffer-boundary transitions.
    for rate in [48_000_u32, 44_100, 16_000, 8_000] {
        let samples = rate as usize * 10 + 7;
        {
            let mut writer = BufWriter::new(File::create(&partial).unwrap());
            for index in 0..samples {
                writer.write_all(&sample(index).to_le_bytes()).unwrap();
            }
            writer.flush().unwrap();
        }
        let baseline = LIVE.load(Ordering::Relaxed);
        PEAK.store(baseline, Ordering::Relaxed);
        let output = pcm_to_wav(&partial, &wav, rate).unwrap();
        let extra = PEAK.load(Ordering::Relaxed).saturating_sub(baseline);
        let output_len = samples * 16_000 / rate as usize;
        assert_eq!(output.len(), output_len);
        assert!(
            extra <= output_len * 4 + 256 * 1024,
            "{rate} Hz: allocated {extra} bytes; output is {} bytes",
            output_len * 4
        );
        for (index, value) in output.iter().enumerate() {
            let position = index as f64 * rate as f64 / 16_000.0;
            let left = position.floor() as usize;
            let fraction = (position - left as f64) as f32;
            let a = sample(left) as f32 / 32768.0;
            let b = sample((left + 1).min(samples - 1)) as f32 / 32768.0;
            assert!((value - (a + (b - a) * fraction)).abs() < 1e-6);
        }
        let mut reader = hound::WavReader::open(&wav).unwrap();
        assert_eq!(reader.spec().sample_rate, 16_000);
        assert_eq!(reader.spec().channels, 1);
        let written: Vec<i16> = reader.samples().map(Result::unwrap).collect();
        assert_eq!(written.len(), output_len);
        for (written, original) in written.iter().zip(&output) {
            assert_eq!(*written, (original.clamp(-1.0, 1.0) * 32767.0) as i16);
        }
        assert!(!partial.exists());
    }
}

fn sample(index: usize) -> i16 {
    ((index * 113) % 60_001) as i32 as i16
}
