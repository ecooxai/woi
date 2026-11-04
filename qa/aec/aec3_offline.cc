// Offline WebRTC AEC3 run with exactly the configuration PipeWire's
// libspa-aec-webrtc (webrtc-audio-processing-1) applies, so canceller settings
// can be measured deterministically without touching any audio device.
//
// build: g++ -O2 -std=c++17 qa/aec/aec3_offline.cc -o aec3_offline \
//          $(pkg-config --cflags --libs webrtc-audio-processing-1)
// usage: aec3_offline far.f32 mic.f32 out.f32 RATE [key=value ...]
//   files: raw mono float32 at RATE; out gets the processed mic.
//   keys (PipeWire aec.args names): webrtc.high_pass_filter (1),
//   webrtc.noise_suppression (1), webrtc.gain_control (0),
//   webrtc.mobile_mode (0), webrtc.transient_suppression (1),
//   webrtc.voice_detection (1); plus ref_lead_ms=N: feed the reference N ms
//   early/late (negative = late, i.e. the mic hears the echo before the
//   reference arrives - what a mis-aligned monitor stream does).
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <modules/audio_processing/include/audio_processing.h>

static std::vector<float> load(const char* p) {
  FILE* f = fopen(p, "rb");
  if (!f) { perror(p); exit(1); }
  std::vector<float> v;
  float b[4096];
  size_t n;
  while ((n = fread(b, sizeof(float), 4096, f)) > 0) v.insert(v.end(), b, b + n);
  fclose(f);
  return v;
}

int main(int argc, char** argv) {
  if (argc < 5) { fprintf(stderr, "usage: %s far mic out rate [k=v...]\n", argv[0]); return 2; }
  std::vector<float> far = load(argv[1]), mic = load(argv[2]);
  int rate = atoi(argv[4]);
  std::map<std::string, std::string> kv;
  for (int i = 5; i < argc; i++) {
    const char* e = strchr(argv[i], '=');
    if (e) kv[std::string(argv[i], e - argv[i])] = e + 1;
  }
  auto b = [&](const char* k, bool d) { auto it = kv.find(k); return it == kv.end() ? d : it->second == "1" || it->second == "true"; };
  int lead = kv.count("ref_lead_ms") ? atoi(kv["ref_lead_ms"].c_str()) * rate / 1000 : 0;

  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  config.echo_canceller.mobile_mode = b("webrtc.mobile_mode", false);
  bool gc = b("webrtc.gain_control", false);
  config.gain_controller1.enabled = gc;
  config.gain_controller1.mode = webrtc::AudioProcessing::Config::GainController1::Mode::kAdaptiveDigital;
  config.gain_controller1.analog_level_minimum = 0;
  config.gain_controller1.analog_level_maximum = 255;
  config.gain_controller2.enabled = gc;
  config.high_pass_filter.enabled = b("webrtc.high_pass_filter", true);
  config.noise_suppression.enabled = b("webrtc.noise_suppression", true);
  config.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kHigh;
  config.transient_suppression.enabled = b("webrtc.transient_suppression", true);
  config.voice_detection.enabled = b("webrtc.voice_detection", true);
  std::unique_ptr<webrtc::AudioProcessing> apm(webrtc::AudioProcessingBuilder().Create());
  apm->ApplyConfig(config);
  webrtc::StreamConfig sc(rate, 1, false);
  webrtc::ProcessingConfig pc = {{sc, sc, sc, sc}};
  if (apm->Initialize(pc) != webrtc::AudioProcessing::kNoError) { fprintf(stderr, "init failed\n"); return 1; }

  const int n = rate / 100;
  std::vector<float> out(mic.size(), 0.f), fbuf(n), mbuf(n), obuf(n), rout(n);
  for (size_t off = 0; off + n <= mic.size(); off += n) {
    for (int i = 0; i < n; i++) {
      long j = (long)off + i + lead;
      fbuf[i] = (j >= 0 && j < (long)far.size()) ? far[j] : 0.f;
      mbuf[i] = mic[off + i];
    }
    const float* fp = fbuf.data();
    float* rp = rout.data();
    apm->ProcessReverseStream(&fp, sc, sc, &rp);
    const float* mp = mbuf.data();
    float* op = obuf.data();
    apm->ProcessStream(&mp, sc, sc, &op);
    memcpy(&out[off], obuf.data(), n * sizeof(float));
  }
  FILE* f = fopen(argv[3], "wb");
  fwrite(out.data(), sizeof(float), out.size(), f);
  fclose(f);
  return 0;
}
