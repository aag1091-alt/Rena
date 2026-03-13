"""
Generate Rena's intro audio using Google Cloud Text-to-Speech.
Run from the agent/ directory:

  python generate_intro.py

Outputs: rena_intro.mp3  (copy this into ios/Rena/Rena/ and add to Xcode target)
"""

import os
from dotenv import load_dotenv
from google.cloud import texttospeech

load_dotenv()

TEXT = (
    "Hello! I'm Rena, your personal health companion. "
    "I'm here to help you reach your health goals. "
    "Let's get started!"
)

def main():
    client = texttospeech.TextToSpeechClient()

    synthesis_input = texttospeech.SynthesisInput(text=TEXT)

    # en-US-Journey-F — warm, natural, conversational female voice
    voice = texttospeech.VoiceSelectionParams(
        language_code="en-US",
        name="en-US-Journey-F",
    )

    audio_config = texttospeech.AudioConfig(
        audio_encoding=texttospeech.AudioEncoding.MP3,
        speaking_rate=0.95,
        pitch=1.5,
    )

    response = client.synthesize_speech(
        input=synthesis_input,
        voice=voice,
        audio_config=audio_config,
    )

    output_path = os.path.join(os.path.dirname(__file__), "rena_intro.mp3")
    with open(output_path, "wb") as f:
        f.write(response.audio_content)

    print(f"Saved: {output_path}")
    print("Next: drag rena_intro.mp3 into Xcode under ios/Rena/Rena/ and add to target.")

if __name__ == "__main__":
    main()
