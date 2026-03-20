# Voice Memo to Obsidian (self-hosted)

(differences from mobob's version: self-hosted speaches.ai instead of Gemini for transcription, and self-hosted Ollama gemma3:12b instead of Gemini for summarization)

Automatically transcribe iOS Voice Memos and create Obsidian notes with AI-generated summaries, tags, and extracted tasks.

Lots of room to update and personalize this, but wanted to crystalize the first version i got up and running in case its useful for anyone (yes, to me. Thank you mobob; - Simon).

## Features

- **Automatic processing** - Polls for new voice memos every 2 minutes via cron
- **AI transcription** - Uses self-hosted speaches.ai "faster-whisper-large-v3" for accurate speech-to-text
- **Smart analysis** - Extracts title, summary, tags, and tasks from content using self-hosted ollama "gemma3:12b"
- **Task extraction** - Pulls out action items with priority levels (#asap, #today, #thisweek, etc.)
- **Obsidian integration** - Creates properly formatted notes with YAML frontmatter
- **Customizable prompts** - Edit AI prompts directly in your Obsidian vault

## How It Works

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ iOS Voice   │────▶│ iCloud Sync │────▶│ Cron Job    │────▶│ Obsidian    │
│ Memos App   │     │ to Mac      │     │ (2 min)     │     │ Note        │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
                                               │
                                               ▼
                                        ┌─────────────┐
                                        │ Ollama API  │
                                        │ Transcribe  │
                                        │ + Analyze   │
                                        └─────────────┘
```

1. Record a voice memo on your iPhone
2. iCloud syncs it to `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/`
3. Cron job detects new files every 2 minutes
4. Script converts audio to MP3 and uploads to speaches.ai
5. Ollama transcribes and analyzes the content
6. A new note is created in your Obsidian vault

## Requirements

- macOS (tested on Sequoia)
- [Homebrew](https://brew.sh)
- Obsidian vault
- 1st GPU with at least 6.5GB ram (for speaches.ai Systran/faster-whisper-large-v3 model)
- 2nd GPU with at least 9GB ram (for ollama gemma3:12b model) (or have 1 GPU with at least 6.5+9=15.5GB of ram)
- iOS Voice Memos app with iCloud sync enabled

## Installation

### 1. Install dependencies

```bash
brew install ffmpeg jq
```

### 2.1 Configure speaches-ai

Make sure your Nvidia CUDA runtime is at least 12.4

As of speaches-ai/speaches v0.9.0-rc.3, long audio recordings (for me it was >=5 mins) cause stt model to endlessly loop. See (#619)[https://github.com/speaches-ai/speaches/issues/619]

I fixed it by patching the stt.py file inside.

First, create the compose.yml file:

```yaml
services:
  speaches-ai:
    ports:
      - 8000:8000
    volumes:
      - ./hf-hub-cache:/home/ubuntu/.cache/huggingface/hub
      - ./patches/stt.py:/home/ubuntu/speaches/src/speaches/routers/stt.py
    environment:
      - LOOPBACK_HOST_URL=http://127.0.0.1:8000
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities:
                - gpu
    image: ghcr.io/speaches-ai/speaches:latest-cuda # uses CUDA >=12.6. Use 'latest-cuda-12.4.1' if running CUDA >=12.4
```

Then run the following to patch:

```bash
cid=$(docker create ghcr.io/speaches-ai/speaches:latest-cuda) && mkdir -p patches && docker cp "$cid":/home/ubuntu/speaches/src/speaches/routers/stt.py ./patches/ && docker rm "$cid"

grep -q 'condition_on_previous_text' patches/stt.py || sed -i '/vad_filter=effective_vad_filter,/a\
            condition_on_previous_text=False,' patches/stt.py
```

This docker compose can be on any machine. Just make sure to note down the speaches-ai server for the SPEACHES_ENDPOINT later. (ex. "http://192.168.1.123:8000")

Download the model on the speaches-ai server:

```
curl "$SPEACHES_ENDPOINT/v1/models/Systran/faster-whisper-large-v3" -X POST
```

In the few tests I did, the model `Systran/faster-whisper-large-v3` works well with multiple languages. If you specify a language (later set as `SPEACHES_LANGUAGE`), it can convert other langauges to chosen language in the transcription.

### 2.2 Configure ollama

Download gemma3:12b or any equivalent model that excels at multilingual and structured/formatted responses. Then make sure it's accessible to the macbook this script runs on. Note the following values for later. Example values:

- OLLAMA_ENDPOINT="http://192.168.1.124:11434"
- OLLAMA_MODEL="gemma3:12b"

### 3. Run the installer

```bash
git clone https://github.com/binary-person/voice-memo-to-obsidian-selfhosted.git
cd voice-memo-to-obsidian-selfhosted
./install.sh
```

The installer will prompt for:
- Your Obsidian vault path
- Your speaches.ai instance endpoint
- Your ollama instance endpoint and ollama model

### 4. Grant Full Disk Access to cron

This is required for cron to read the Voice Memos directory.

1. Open **System Settings → Privacy & Security → Full Disk Access**
2. Click **+** button
3. Press **Cmd+Shift+G** and type: `/usr/sbin/cron`
4. Select `cron` and enable the toggle

## Upgrading

When a new version is released:

```bash
cd voice-memo-to-obsidian-selfhosted
git pull
./upgrade.sh
```

The upgrade script **only updates the processing scripts**. Your config and customized prompts are preserved.

## File Types

### Upgradable Files (overwritten by `upgrade.sh`)

These are the core scripts that may receive bug fixes or new features:

| File | Location |
|------|----------|
| `voice-memo-to-obsidian.sh` | `~/.config/voice-memo/scripts/` |
| `voice-memo-watcher.sh` | `~/.config/voice-memo/scripts/` |

### User-Editable Files (never overwritten)

These files are created from samples on first install and never touched again:

| File | Location | Sample |
|------|----------|--------|
| `config` | `~/.config/voice-memo/` | `config.sample` |
| `transcription-prompt.md` | `{vault}/Areas/Voice Memo Pipeline/` | `prompts/transcription-prompt.sample.md` |
| `analysis-prompt.md` | `{vault}/Areas/Voice Memo Pipeline/` | `prompts/analysis-prompt.sample.md` |
| `condense-prompt.md` | `{vault}/Areas/Voice Memo Pipeline/` | `prompts/condense-prompt.sample.md` |

To reset a prompt to defaults, delete it and run `./install.sh` (it will skip existing files and only create missing ones).

## Output Format

Each voice memo becomes a note in `Daily/Babble/`:

```markdown
---
tags:
  - voicememos
  - meeting
  - project
author:
  - "[[Me]]"
created: "2024-01-15"
time: "14:30"
status:
---

In addition, the transcript file `.vtt` is stored at `Daily/Babble/{Note name}.vtt`. To easily view this in Obsidian, use enable community plugin "Custom File Extensions" and add `vtt` to the list.

## Tasks

- [ ] Send follow-up email #today
- [ ] Schedule team meeting #thisweek

## Summary

Discussion about project timeline and next steps for the Q1 launch.

## Transcript

Hey, so I just got out of the meeting and wanted to capture a few thoughts...
```

## Configuration

### Config file (`~/.config/voice-memo/config`)

```bash
SPEACHES_ENDPOINT="http://192.168.1.123:8000"
SPEACHES_MODEL="Systran/faster-whisper-large-v3"
SPEACHES_LANGUAGE="en"
OBSIDIAN_VAULT="/path/to/your/vault"
OLLAMA_ENDPOINT="http://192.168.1.124:11434"
OLLAMA_MODEL="gemma3:12b"
```

### Polling interval

The default is every 2 minutes. To change it, edit your crontab:

```bash
crontab -e
```

Change `*/2` to your desired interval:
- `*/1` = every minute
- `*/5` = every 5 minutes
- `*/10` = every 10 minutes

### AI Prompts

Prompts are stored in your Obsidian vault at `Areas/Voice Memo Pipeline/`:

| File | Purpose |
|------|---------|
| `transcription-prompt.md` | Instructions for transcription |
| `analysis-prompt.md` | Instructions for title, summary, tags, and task extraction |
| `condense-prompt.md` | Instructions for condensing transcription to something readable |

Edit these directly in Obsidian to customize the AI behavior. Compare with the `.sample.md` files in this repo to see new features after upgrading.

## File Locations Summary

| Location | Purpose |
|----------|---------|
| `~/.config/voice-memo/config` | API key and vault path |
| `~/.config/voice-memo/scripts/` | Processing scripts |
| `~/.config/voice-memo/processed/` | Markers for processed files |
| `~/.config/voice-memo/voice-memo.log` | Activity log |
| `~/.config/voice-memo/cron.log` | Cron output |
| `{vault}/Areas/Voice Memo Pipeline/` | AI prompts |
| `{vault}/Daily/Babble/` | Output notes |

## Logs

```bash
# Watch processing activity
tail -f ~/.config/voice-memo/voice-memo.log

# Check cron output
cat ~/.config/voice-memo/cron.log
```

## Manual Usage

Process all recent memos:
```bash
~/.config/voice-memo/scripts/voice-memo-watcher.sh
```

Process a specific file:
```bash
~/.config/voice-memo/scripts/voice-memo-to-obsidian.sh "/path/to/recording.m4a"
```

## Troubleshooting

### "Operation not permitted" errors

The cron daemon needs Full Disk Access. See installation step 4.

### Watcher runs but finds 0 files

- Verify Full Disk Access is granted to `/usr/sbin/cron`
- Check that Voice Memos are syncing to your Mac (open Voice Memos app on Mac)

### Files not being detected

The watcher only looks for files modified in the last 10 minutes. For older files, process them manually:

```bash
~/.config/voice-memo/scripts/voice-memo-to-obsidian.sh "/path/to/file.m4a"
```

Otherwise it can very likely be a iCloud sync glitch. More often than not one side or the other will get stuck. Successive reboots of your phone/Mac usually solve this, but the best solution is time.

## Uninstall

```bash
./uninstall.sh
```

This removes the cron job and config directory. Notes and prompts in your Obsidian vault are preserved.

## Privacy

100% private. You can run this in the middle of a dessert without WiFi and it should still transcribe and analyze.

With that in mind, some important reminders for privacy and protection:

- If iCloud Advanced Data Protection is not on, your iCloud backups of your voice memos are not protected and can be read by Apple.
- If your speaches-ai or ollama instance is outside of your LAN, run them through tailscale. If you want to put them on a publicly accessible IP, expose it locally, and route both through a reverse proxy like Nginx Proxy Manager. If you go with that route, make sure timeouts are disabled in the nginx config so your transcription/analysis don't get cut short:

```yaml
# 3 day timeout
proxy_read_timeout 259200s;
proxy_connect_timeout 259200s;
proxy_send_timeout 259200s;
```

## Credits

Inspired by [drew.tech's voice memo workflow](https://drew.tech/posts/ios-memos-obsidian-claude).

## License

MIT
