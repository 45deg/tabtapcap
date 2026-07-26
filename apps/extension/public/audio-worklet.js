class PcmCaptureProcessor extends AudioWorkletProcessor {
  chunks = [];
  chunkSamples;

  constructor() {
    super();
    this.chunkSamples = Math.max(1, Math.round(sampleRate * 0.5));
  }

  process(inputs) {
    const channels = inputs[0];
    const frames = channels?.[0]?.length ?? 0;
    if (!channels || channels.length === 0 || frames === 0) return true;

    const mono = new Float32Array(frames);
    for (let channelIndex = 0; channelIndex < channels.length; channelIndex += 1) {
      const channel = channels[channelIndex];
      for (let frameIndex = 0; frameIndex < frames; frameIndex += 1) {
        mono[frameIndex] += (channel[frameIndex] ?? 0) / channels.length;
      }
    }

    for (const sample of mono) this.chunks.push(sample);
    while (this.chunks.length >= this.chunkSamples) {
      const samples = this.chunks.splice(0, this.chunkSamples);
      const pcm = new Int16Array(samples.length);
      for (let index = 0; index < samples.length; index += 1) {
        const sample = Math.max(-1, Math.min(1, samples[index] ?? 0));
        pcm[index] = sample < 0 ? sample * 32768 : sample * 32767;
      }
      this.port.postMessage(pcm, [pcm.buffer]);
    }
    return true;
  }
}

registerProcessor("pcm-capture", PcmCaptureProcessor);
