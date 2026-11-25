# Third-party notices

Voice Assistant for Mac links these libraries and downloads these models (each once, checked against a fixed SHA-256).
Each keeps its own license.

## Libraries

The speech engines come with [thumbfree-mac](https://github.com/shivam098/thumbfree-mac)'s `ThumbFreeSpeech` and are
linked into the app as static libraries: `CSherpaOnnx.xcframework` and `CWhisper.xcframework`, built by thumbfree-mac's
`.github/workflows/engines.yml` from the pinned sources in its `scripts/engines` and published as the
[`engines-sherpa-onnx-2.0.1-3`](https://github.com/shivam098/thumbfree-mac/releases/tag/engines-sherpa-onnx-2.0.1-3) and
[`engines-whisper-1.9.5-3`](https://github.com/shivam098/thumbfree-mac/releases/tag/engines-whisper-1.9.5-3) releases.
Each engine's zip has its notice next to the xcframework, `CSherpaOnnx-NOTICE.txt` and `CWhisper-NOTICE.txt` (also
attached to the releases): the license texts of everything below that it links in, with ONNX Runtime's own third-party
notices. The app carries this file and both notices in `Voice Assistant.app/Contents/Resources`
([`scripts/make-app.sh`](scripts/make-app.sh)). thumbfree-mac's
[THIRD-PARTY-NOTICES.md](https://github.com/shivam098/thumbfree-mac/blob/main/THIRD-PARTY-NOTICES.md) says how its build
checks that each notice covers everything its engine links in, and the two marks for Xcode's linker that are the only
changes to the code.

| Component | Used for | License |
|---|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 2.0.1 (C API, its universal2 static libraries without text-to-speech) | Running ThumbFree's English dictation models | Apache-2.0 |
| [kaldi-native-fbank](https://github.com/csukuangfj/kaldi-native-fbank) 1.22.4, [kaldi-decoder](https://github.com/k2-fsa/kaldi-decoder) 0.3.0, [kaldifst](https://github.com/k2-fsa/kaldifst) 1.8.0, [OpenFst](https://github.com/csukuangfj/openfst) 1.8.5, [simple-sentencepiece](https://github.com/pkufool/simple-sentencepiece) 0.7 (inside sherpa-onnx) | Audio features, decoding, tokens | Apache-2.0 |
| [KISS FFT](https://github.com/mborgerding/kissfft) (inside kaldi-native-fbank) | Audio features | BSD-3-Clause |
| [darts-clone](https://github.com/s-yata/darts-clone) (inside simple-sentencepiece) | Tokens for the punctuation model | BSD-2-Clause |
| [ThreadPool](https://github.com/progschj/ThreadPool) by Jakob Progsch and Václav Zeman (inside simple-sentencepiece) | Parallel tokenizing | Zlib |
| [hclust-cpp](https://github.com/csukuangfj/hclust-cpp) with fastcluster (inside sherpa-onnx) | Speaker clustering (not used) | BSD-2-Clause |
| [utf8proc](https://github.com/JuliaStrings/utf8proc) 2.12.0 (inside sherpa-onnx) | Unicode text handling | MIT, and the Unicode data license |
| [nlohmann/json](https://github.com/nlohmann/json) 3.12.0 (inside sherpa-onnx and ONNX Runtime) | Reading JSON | MIT |
| [Eigen](https://gitlab.com/libeigen/eigen) 5.0.1 (inside kaldi-decoder) and Eigen 3.4.90 at commit [`1d8b82b0`](https://gitlab.com/libeigen/eigen/-/commit/1d8b82b0740839c0de7f1242a3585e3390ff5f33) (inside ONNX Runtime) | Linear algebra | MPL-2.0; used unmodified, source code: [5.0.1](https://gitlab.com/libeigen/eigen/-/archive/5.0.1/eigen-5.0.1.tar.gz), [1d8b82b0](https://gitlab.com/libeigen/eigen/-/archive/1d8b82b0740839c0de7f1242a3585e3390ff5f33/eigen-1d8b82b0740839c0de7f1242a3585e3390ff5f33.tar.gz) |
| [ONNX Runtime](https://onnxruntime.ai) 1.28.2, with its MLAS kernels (inside sherpa-onnx: the static build in [onnxruntime-libs v1.28.2](https://github.com/csukuangfj/onnxruntime-libs/releases/tag/v1.28.2)) | Neural network inference | MIT |
| [protobuf](https://github.com/protocolbuffers/protobuf), [re2](https://github.com/google/re2) (inside ONNX Runtime) | Reading models, text patterns | BSD-3-Clause |
| [abseil](https://github.com/abseil/abseil-cpp), [flatbuffers](https://github.com/google/flatbuffers), [ONNX](https://github.com/onnx/onnx) (inside ONNX Runtime) | Containers, the model format | Apache-2.0 |
| [SafeInt](https://github.com/dcleblanc/SafeInt), [GSL](https://github.com/microsoft/GSL), [date](https://github.com/HowardHinnant/date) (inside ONNX Runtime) | Checked arithmetic, spans, times | MIT |
| [Boost](https://www.boost.org), header-only parts (inside ONNX Runtime) | Type lists | BSL-1.0 |
| MurmurHash3 by Austin Appleby (inside ONNX Runtime) | Hashing | Public domain (ONNX Runtime's notices list it as MIT) |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 1.9.5 with [ggml](https://github.com/ggml-org/ggml) (Metal and Accelerate) | Running the Whisper models ("Hey Jarvis", commands, Hindi + English dictation) and Silero | MIT |

## Models

Downloaded the first time they're needed, from the addresses below, into `~/Library/Application Support/VoiceAssistant/models`
(or used from ThumbFree for Mac's models folder when it already has them), each checked against its SHA-256.

| Model | Used for | License |
|---|---|---|
| [OpenAI Whisper](https://github.com/openai/whisper) `small.en` and `base.en` (ggml from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp): `ggml-small.en-q8_0.bin`, `ggml-base.en-q8_0.bin`, `ggml-base.en.bin`) | "Hey Jarvis" and commands | MIT |
| [Silero VAD](https://github.com/snakers4/silero-vad) (ggml from [ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad): `ggml-silero-v6.2.0.bin`) | Telling speech from noise and finding pauses | MIT |
| [Oriserve/Whisper-Hindi2Hinglish-Swift](https://huggingface.co/Oriserve/Whisper-Hindi2Hinglish-Swift), fine-tuned from [openai/whisper-base](https://huggingface.co/openai/whisper-base) (`ggml-hinglish-swift-q8_0.bin`) | Hindi + English dictation | Apache-2.0 (fine-tune); MIT (OpenAI Whisper base model, mel filters, vocabulary) |
| [Oriserve/Whisper-Hindi2Hinglish-Apex](https://huggingface.co/Oriserve/Whisper-Hindi2Hinglish-Apex), fine-tuned from [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) (`ggml-hinglish-apex-q8_0.bin`) | Hindi + English dictation, accurate | Apache-2.0 (fine-tune); MIT (OpenAI Whisper base model, mel filters, vocabulary) |

The Whisper and Silero models are used unmodified. OpenAI Whisper is Copyright (c) 2022 OpenAI, MIT License.

## The AI brain (downloaded only on request)

| Component | Used for | License |
|---|---|---|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server`, release b12483 (the macOS Apple silicon build, `llama-b12483-bin-macos-arm64.tar.gz`) | Runs the AI brain's model on this Mac | MIT |
| [Qwen/Qwen3-4B-Instruct-2507](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507), Q4_0 GGUF from [unsloth/Qwen3-4B-Instruct-2507-GGUF](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF) | The AI brain: plans requests the fixed commands don't cover | Apache-2.0 |

Neither is part of the app: the AI brain's settings download them only when you ask, from their official releases (the
llama.cpp GitHub release and the Hugging Face repository above), check each file's SHA-256, and run them unchanged on
this Mac. llama.cpp is Copyright (c) 2023-2026 The ggml authors, MIT License. Qwen3-4B-Instruct-2507 is by the Qwen
team (Alibaba Cloud), Apache License 2.0 (<https://www.apache.org/licenses/LICENSE-2.0>); the GGUF file is unsloth's
4-bit (Q4_0) conversion of it, under the same license. Both are provided "AS IS", without warranties or conditions of
any kind.

## Oriserve/Whisper-Hindi2Hinglish-Swift and Apex

Models by [Oriserve](https://oriserve.com). Licensed under the Apache License, Version 2.0
(<https://www.apache.org/licenses/LICENSE-2.0>); a copy of the license is attached to the
[`models-hinglish-swift-1`](https://github.com/shivam098/windows-voice-assistant/releases/tag/models-hinglish-swift-1) and
[`models-hinglish-apex-1`](https://github.com/shivam098/windows-voice-assistant/releases/tag/models-hinglish-apex-1)
releases, which the app downloads them from.

They are fine-tuned from OpenAI's `whisper-base` and `whisper-large-v3-turbo`, and the converted files also contain
OpenAI Whisper's mel filter bank and tokenizer vocabulary. Those are Copyright (c) 2022 OpenAI under the MIT License;
OpenAI's license text is attached to the same releases.

**Changes made:** the original Hugging Face weights were converted to the ggml format and quantized to 8-bit (q8_0) so
whisper.cpp can run them; the models themselves were not retrained. The steps are in
[tools/ModelConvert/README.md](https://github.com/shivam098/windows-voice-assistant/blob/main/tools/ModelConvert/README.md)
in the Windows Voice Assistant repository. The models are distributed "AS IS", without warranties or conditions of any
kind.
