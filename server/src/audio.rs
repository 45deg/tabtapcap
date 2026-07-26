use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};

pub const HEADER_SIZE: usize = 28;

#[derive(Debug)]
pub struct AudioFrame<'a> {
    pub sequence: u32,
    pub start_sample: u64,
    pub sample_rate: u32,
    pub payload: &'a [u8],
}

pub fn decode_frame(data: &[u8]) -> Result<AudioFrame<'_>> {
    if data.len() < HEADER_SIZE || &data[0..4] != b"LTCA" {
        bail!("音声フレームのヘッダーが不正です。");
    }
    if data[4] != 1 || data[24] != 1 || data[25] != 1 {
        bail!("対応していない音声フォーマットです。");
    }
    let header_size = u16::from_le_bytes([data[6], data[7]]) as usize;
    if header_size != HEADER_SIZE || !(data.len() - header_size).is_multiple_of(2) {
        bail!("音声フレームのサイズが不正です。");
    }
    Ok(AudioFrame {
        sequence: u32::from_le_bytes(data[8..12].try_into()?),
        start_sample: u64::from_le_bytes(data[12..20].try_into()?),
        sample_rate: u32::from_le_bytes(data[20..24].try_into()?),
        payload: &data[header_size..],
    })
}

pub fn pcm_to_wav(partial_path: &Path, wav_path: &Path, sample_rate: u32) -> Result<Vec<f32>> {
    let bytes = fs::read(partial_path).context("録音音声を読み込めませんでした")?;
    if bytes.is_empty() || bytes.len() % 2 != 0 {
        bail!("録音音声が空か破損しています。");
    }
    let input: Vec<f32> = bytes
        .chunks_exact(2)
        .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]) as f32 / 32768.0)
        .collect();
    let output = resample_linear(&input, sample_rate, 16_000);
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: 16_000,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(wav_path, spec)?;
    for sample in &output {
        writer.write_sample((sample.clamp(-1.0, 1.0) * 32767.0) as i16)?;
    }
    writer.finalize()?;
    fs::remove_file(partial_path)?;
    Ok(output)
}

pub fn read_wav(path: &Path) -> Result<Vec<f32>> {
    let mut reader = hound::WavReader::open(path)?;
    if reader.spec().sample_rate != 16_000 || reader.spec().channels != 1 {
        bail!("WAVは16kHzモノラルではありません。");
    }
    reader
        .samples::<i16>()
        .map(|sample| Ok(sample? as f32 / 32768.0))
        .collect()
}

fn resample_linear(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to {
        return input.to_vec();
    }
    let output_len = ((input.len() as u64 * to as u64) / from as u64) as usize;
    (0..output_len)
        .map(|index| {
            let position = index as f64 * from as f64 / to as f64;
            let left = position.floor() as usize;
            let fraction = (position - left as f64) as f32;
            let a = input.get(left).copied().unwrap_or(0.0);
            let b = input.get(left + 1).copied().unwrap_or(a);
            a + (b - a) * fraction
        })
        .collect()
}
