use std::fs;
use std::io::{BufReader, Read};
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
    let file = fs::File::open(partial_path).context("録音音声を読み込めませんでした")?;
    let byte_len = file.metadata()?.len();
    if byte_len == 0 || byte_len % 2 != 0 || sample_rate == 0 {
        bail!("録音音声が空か破損しています。");
    }
    let sample_count = byte_len / 2;
    let output_len = usize::try_from(
        sample_count
            .checked_mul(16_000)
            .context("録音音声が大きすぎます。")?
            / u64::from(sample_rate),
    )?;
    let mut reader = BufReader::with_capacity(64 * 1024, file);
    let mut read_sample = || -> Result<f32> {
        let mut bytes = [0; 2];
        reader.read_exact(&mut bytes)?;
        Ok(i16::from_le_bytes(bytes) as f32 / 32768.0)
    };
    let mut left = 0;
    let mut a = read_sample()?;
    let mut b = if sample_count > 1 { read_sample()? } else { a };
    let mut output = Vec::with_capacity(output_len);
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: 16_000,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(wav_path, spec)?;
    for index in 0..output_len {
        let position = index as f64 * sample_rate as f64 / 16_000.0;
        let target = position.floor() as u64;
        while left < target {
            a = b;
            left += 1;
            b = if left + 1 < sample_count {
                read_sample()?
            } else {
                a
            };
        }
        let fraction = (position - target as f64) as f32;
        let sample = a + (b - a) * fraction;
        output.push(sample);
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
