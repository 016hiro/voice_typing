# Fixture attribution

## jfk_en_short.wav

- **Source**: `tests/jfk.flac` from [openai/whisper](https://github.com/openai/whisper/tree/main/tests)
- **Original content**: Excerpt from President John F. Kennedy's 1961 inaugural address — "And so my fellow Americans, ask not what your country can do for you..."
- **License**: Public Domain. US federal government works are not subject to copyright protection (17 U.S.C. § 105). This pre-1978 recording is in the public domain by default.
- **Processing**: Re-encoded from source FLAC to 16 kHz mono s16 WAV via `ffmpeg` (see `Scripts/fetch_english_fixtures.sh`).

## Self-recorded fixtures

Any `*.wav` not listed above was recorded by the repo maintainer via `Scripts/record_fixture.sh` and is their own copyrighted work, used here as a regression test fixture.

## LibriSpeech dev-clean fixtures

- **Corpus**: LibriSpeech dev-clean (Vassil Panayotov et al., 2015)
- **License**: CC BY 4.0 — https://creativecommons.org/licenses/by/4.0/
- **Underlying recordings**: Public domain, from LibriVox audiobooks.
- **Citation**: Panayotov, V. et al. "LibriSpeech: an ASR corpus based on public domain audio books." ICASSP 2015.

Fixtures extracted:
- librispeech_1272_128104_short: LibriSpeech dev-clean 1272-128104-0000
- librispeech_1462_170138_short: LibriSpeech dev-clean 1462-170138-0006
- librispeech_1673_143396_short: LibriSpeech dev-clean 1673-143396-0002
- librispeech_174_168635_short: LibriSpeech dev-clean 174-168635-0005
- librispeech_1919_142785_short: LibriSpeech dev-clean 1919-142785-0001
- librispeech_1988_147956_short: LibriSpeech dev-clean 1988-147956-0004
- librispeech_1993_147149_short: LibriSpeech dev-clean 1993-147149-0000
- librispeech_1272_128104_long: LibriSpeech dev-clean, concat of 1272-128104-0000..1272-128104-0005
- librispeech_1272_135031_long: LibriSpeech dev-clean, concat of 1272-135031-0000..1272-135031-0017

## FLEURS Mandarin (cmn_hans_cn) fixtures

- **Corpus**: FLEURS (Few-shot Learning Evaluation of Universal Representations of Speech), `cmn_hans_cn` dev split
- **Source**: [google/fleurs on Hugging Face](https://huggingface.co/datasets/google/fleurs)
- **License**: CC BY 4.0 — https://creativecommons.org/licenses/by/4.0/
- **Citation**: Conneau, A. et al. "FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech." IEEE SLT 2022.

Fixtures extracted:
- fleurs_zh_short_3s_f_1554: FLEURS dev #1554 file 7434894266661195533.wav (FEMALE, 3.3s)
- fleurs_zh_med_7s_m_1548: FLEURS dev #1548 file 8722658281954920812.wav (MALE, 6.8s)
- fleurs_zh_medlong_8s_f_1566: FLEURS dev #1566 file 17653389814525369948.wav (FEMALE, 8.0s)
- fleurs_zh_long_12s_m_1529: FLEURS dev #1529 file 4742596756523997399.wav (MALE, 12.0s)
- fleurs_zh_xlong_18s_m_1542: FLEURS dev #1542 file 3890233952096932600.wav (MALE, 18.0s)
