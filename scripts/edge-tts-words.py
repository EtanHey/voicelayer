#!/usr/bin/env python3
"""
edge-tts with word-level timing metadata.

Usage: python3 edge-tts-words.py --text "Hello world" --voice en-US-JennyNeural \
           --rate "+0%" --write-media out.mp3 --write-metadata out.json

Outputs NDJSON metadata with word boundaries:
  {"type": "WordBoundary", "offset": 1000000, "text": "Hello"}
  {"type": "WordBoundary", "offset": 4500000, "text": "world"}

Offsets are in 100-nanosecond units (same as edge-tts internal format).
"""

import argparse
import asyncio
import json
import sys

import edge_tts


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--text", required=True)
    parser.add_argument("--voice", default="en-US-JennyNeural")
    parser.add_argument("--rate", default="+0%")
    parser.add_argument("--write-media", required=True)
    parser.add_argument("--write-metadata", required=True)
    args = parser.parse_args()

    comm = edge_tts.Communicate(
        text=args.text,
        voice=args.voice,
        rate=args.rate,
        boundary="WordBoundary",
    )

    words = []
    audio_chunks = []

    async for chunk in comm.stream():
        if chunk["type"] == "audio":
            audio_chunks.append(chunk["data"])
        elif chunk["type"] == "WordBoundary":
            words.append({
                "type": "WordBoundary",
                "offset": chunk["offset"],
                "duration": chunk["duration"],
                "text": chunk["text"],
            })

    # Write audio
    with open(args.write_media, "wb") as f:
        for data in audio_chunks:
            f.write(data)

    # Write word-level metadata (NDJSON)
    with open(args.write_metadata, "w") as f:
        for w in words:
            f.write(json.dumps(w) + "\n")


if __name__ == "__main__":
    asyncio.run(main())
