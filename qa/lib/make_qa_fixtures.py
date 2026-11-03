#!/usr/bin/env python3
"""Extra spoken fixtures for the QA suite, made with the same TTS path as
research/make_fixtures.py (gpt-realtime-1.5 over the Codex login).

  research/.venv/bin/python qa/lib/make_qa_fixtures.py
"""
import asyncio, sys
from pathlib import Path

QA = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QA.parent / "research"))
import make_fixtures as mf  # noqa: E402
import probe_realtime as pr  # noqa: E402

PHRASES = [
    ("11_long_story", "Tell me a long story about a lighthouse keeper. Make it at least one minute long.", "marin"),
    ("12_mars_facts", "Tell me three interesting facts about Mars.", "cedar"),
    ("13_show_image", "Show me the image sample dot p n g", "marin"),
    ("14_play_tone", "Play the audio file tone dot wav", "cedar"),
]

async def main():
    out = QA / "fixtures"
    out.mkdir(exist_ok=True)
    for name, text, voice in PHRASES:
        p = out / f"{name}.wav"
        if p.exists():
            continue
        pcm, said = await mf.tts_one(text, voice)
        pr.write_wav(p, mf.trim(pcm))
        print(name, repr(said))

asyncio.run(main())
