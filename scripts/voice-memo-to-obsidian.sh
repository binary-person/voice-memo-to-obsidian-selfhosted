#!/bin/zsh
#
# voice-memo-to-obsidian.sh
# Transcribes voice memos using speaches.ai and creates Obsidian notes
#

set -e

# Configuration - these are set by install.sh
CONFIG_DIR="$HOME/.config/voice-memo"
CONFIG_FILE="$CONFIG_DIR/config"
PROCESSED_DIR="$CONFIG_DIR/processed"
LOG_FILE="$CONFIG_DIR/voice-memo.log"

# Load config
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found at $CONFIG_FILE"
    echo "Run install.sh first"
    exit 1
fi
source "$CONFIG_FILE"

# Validate required config
if [[ -z "$SPEACHES_ENDPOINT" ]]; then
    echo "ERROR: SPEACHES_ENDPOINT not set in config"
    exit 1
fi

if [[ -z "$SPEACHES_MODEL" ]]; then
    echo "ERROR: SPEACHES_MODEL not set in config"
    exit 1
fi

if [[ -z "$OLLAMA_ENDPOINT" ]]; then
    echo "ERROR: OLLAMA_ENDPOINT not set in config"
    exit 1
fi

if [[ -z "$OBSIDIAN_VAULT" ]]; then
    echo "ERROR: OBSIDIAN_VAULT not set in config"
    exit 1
fi

# Derived paths
VOICE_MEMOS_PATH="$OBSIDIAN_VAULT/Daily/Babble"
PROMPTS_DIR="$OBSIDIAN_VAULT/Areas/Voice Memo Pipeline"

# AI settings
SPEACHES_MODEL="${SPEACHES_MODEL:-Systran/faster-whisper-large-v3}"
OLLAMA_MODEL="${OLLAMA_MODEL:-gemma3:12b}"

# Find ffmpeg
if [[ -x "/opt/homebrew/bin/ffmpeg" ]]; then
    FFMPEG="/opt/homebrew/bin/ffmpeg"
elif [[ -x "/usr/local/bin/ffmpeg" ]]; then
    FFMPEG="/usr/local/bin/ffmpeg"
else
    FFMPEG=$(which ffmpeg 2>/dev/null || echo "")
fi

if [[ -z "$FFMPEG" ]]; then
    echo "ERROR: ffmpeg not found. Install with: brew install ffmpeg"
    exit 1
fi

# Find jq
if [[ -x "/opt/homebrew/bin/jq" ]]; then
    JQ="/opt/homebrew/bin/jq"
elif [[ -x "/usr/local/bin/jq" ]]; then
    JQ="/usr/local/bin/jq"
else
    JQ=$(which jq 2>/dev/null || echo "")
fi

if [[ -z "$JQ" ]]; then
    echo "ERROR: jq not found. Install with: brew install jq"
    exit 1
fi

# Create directories
mkdir -p "$PROCESSED_DIR" "$VOICE_MEMOS_PATH" "$(dirname "$LOG_FILE")"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check for required argument
if [[ -z "$1" ]]; then
    log "ERROR: No input file provided"
    echo "Usage: $0 <path-to-audio-file>"
    exit 1
fi

INPUT_FILE="$1"
FILENAME=$(basename "$INPUT_FILE")

# Skip if not an audio file
if [[ ! "$FILENAME" =~ \.(m4a|mp3|wav|aac)$ ]]; then
    log "Skipping non-audio file: $FILENAME"
    exit 0
fi

# Skip if already processed
PROCESSED_MARKER="$PROCESSED_DIR/${FILENAME}.done"
if [[ -f "$PROCESSED_MARKER" ]]; then
    log "Already processed: $FILENAME"
    exit 0
fi

log "Processing: $FILENAME"

# Preprocess audio for transcription
TEMP_DIR=$(mktemp -d)
PREPROCESSED_FILE="$TEMP_DIR/audio.m4a"
TEMP_INPUT="$TEMP_DIR/input.${FILENAME##*.}"
TRANSCRIPTION_FILE="$TEMP_DIR/transcription.vtt"
TRANSCRIPTION_OVERRIDE_FILE="$PROMPTS_DIR/temp-transcription-override.vtt"

# Check for temporary transcription override
if [[ -f "$TRANSCRIPTION_OVERRIDE_FILE" && -n "$(tr -d '[:space:]' < "$TRANSCRIPTION_OVERRIDE_FILE")" ]]; then
    log "Using transcription override: $TRANSCRIPTION_OVERRIDE_FILE"

    if ! cp "$TRANSCRIPTION_OVERRIDE_FILE" "$TRANSCRIPTION_FILE" 2>&1; then
        log "ERROR: Failed to copy transcription override"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
else
# Copy input file to temp (avoids FDA issues with ffmpeg)
log "Copying to temp..."
if ! cp "$INPUT_FILE" "$TEMP_INPUT" 2>&1; then
    log "ERROR: Failed to copy input file"
    rm -rf "$TEMP_DIR"
    exit 1
fi

log "Preprocessing audio..."
FFMPEG_LOG="$TEMP_DIR/ffmpeg.log"
if ! "$FFMPEG" -i "$TEMP_INPUT" -af "highpass=f=80,speechnorm=e=12:r=0.0005:l=1" -y "$PREPROCESSED_FILE" 2>"$FFMPEG_LOG"; then
    log "ERROR: ffmpeg failed"
    log "ERROR: $(cat "$FFMPEG_LOG" | tail -5)"
    rm -rf "$TEMP_DIR"
    exit 1
fi

if [[ ! -f "$PREPROCESSED_FILE" ]]; then
    log "ERROR: Preprocessed audio file not created"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Get file size for upload
FILE_SIZE=$(stat -f%z "$PREPROCESSED_FILE")
log "Audio file size: $FILE_SIZE bytes"

# Step 1: Transcribe with speaches.ai
log "Requesting transcription..."

# Read transcription prompt
if [[ -f "$PROMPTS_DIR/transcription-prompt.md" ]]; then
    TRANSCRIPTION_PROMPT=$(cat "$PROMPTS_DIR/transcription-prompt.md")
else
    TRANSCRIPTION_PROMPT="Transcribe clearly and preserve punctuation."
fi

# Build transcription request
TRANSCRIPTION_CURL_ARGS=(
    -s
    "${SPEACHES_ENDPOINT}/v1/audio/transcriptions"
    -F "file=@${PREPROCESSED_FILE}"
    -F "prompt=${TRANSCRIPTION_PROMPT}"
    -F "model=${SPEACHES_MODEL}"
    -F "response_format=vtt"
    -F "temperature=0"
    -F "stream=false"
)

if [[ -n "$SPEACHES_LANGUAGE" ]]; then
    TRANSCRIPTION_CURL_ARGS+=(-F "language=${SPEACHES_LANGUAGE}")
fi

if ! curl "${TRANSCRIPTION_CURL_ARGS[@]}" -o "$TRANSCRIPTION_FILE" 2>/dev/null; then
    log "ERROR: Failed to get transcription"
    rm -rf "$TEMP_DIR"
    exit 1
fi

if [[ ! -s "$TRANSCRIPTION_FILE" ]]; then
    log "ERROR: Transcription file is empty"
    rm -rf "$TEMP_DIR"
    exit 1
    fi
fi

# Convert VTT to plain text for downstream analysis
TRANSCRIPT=$(awk '
BEGIN { in_cue=0 }
{
    gsub(/\r/, "", $0)
    if ($0 ~ /^WEBVTT/) next
    if ($0 ~ /^[[:space:]]*$/) next
    if ($0 ~ /^[0-9]+$/) next
    if ($0 ~ /-->/) next
    if ($0 ~ /^(NOTE|STYLE|REGION)/) next
    print
}' "$TRANSCRIPTION_FILE" | awk '!seen[$0]++')

if [[ -z "$TRANSCRIPT" ]]; then
    log "ERROR: Failed to extract transcript text from VTT"
    log "Response: $(cat "$TRANSCRIPTION_FILE")"
    rm -rf "$TEMP_DIR"
    exit 1
fi

log "Transcription received (${#TRANSCRIPT} chars)"

# Step 2: Analyze for title, summary, tags
log "Analyzing content..."

# Read analysis prompt from Obsidian (or use default)
if [[ -f "$PROMPTS_DIR/analysis-prompt.md" ]]; then
    ANALYSIS_PROMPT_BASE=$(cat "$PROMPTS_DIR/analysis-prompt.md")
else
    ANALYSIS_PROMPT_BASE="Analyze this voice memo transcript and return a JSON object with exactly these fields:
- title: a concise descriptive title (3-7 words)
- summary: a 1-2 sentence summary of the main points
- tags: an array of 2-4 relevant topic tags (single words, lowercase, no # symbol)
- todos: an array of fully formatted Obsidian task strings. Format each as:
  \"- [ ] Task description #priority\"
  Where priority is one of: asap, today, thisweek, thismonth, thisyear

If no todos are found, return an empty array for todos.

Return ONLY valid JSON, no other text.

Transcript:"
fi
ANALYSIS_PROMPT="${ANALYSIS_PROMPT_BASE}
${TRANSCRIPT}"

# Use jq to safely construct the JSON payload
ANALYSIS_PAYLOAD=$("$JQ" -n \
    --arg model "$OLLAMA_MODEL" \
    --arg prompt "$ANALYSIS_PROMPT" \
    '{
        model: $model,
        prompt: $prompt,
        format: "json",
        stream: false
    }')

ANALYSIS_FILE="$TEMP_DIR/analysis.json"
curl -s -X POST \
    "${OLLAMA_ENDPOINT}/api/generate" \
    -H "Content-Type: application/json" \
    -d "$ANALYSIS_PAYLOAD" -o "$ANALYSIS_FILE" 2>/dev/null

ANALYSIS_JSON=$("$JQ" -r '.response // empty' "$ANALYSIS_FILE" 2>/dev/null)

rm -f "$CONFIG_DIR/last-analysis-response.json" "$CONFIG_DIR/last-analysis-response-raw.json"
cp "$ANALYSIS_FILE" "$CONFIG_DIR/last-analysis-response-raw.json"

if [[ -z "$ANALYSIS_JSON" ]]; then
    log "WARNING: Failed to get analysis, using defaults"
    log "Analysis response: $(cat "$ANALYSIS_FILE")"
    TITLE="Voice Memo"
    SUMMARY="Voice memo recorded on $(date '+%Y-%m-%d')"
    TAGS='["voicememos"]'
    TODOS='[]'
else
    echo "$ANALYSIS_JSON" > "$CONFIG_DIR/last-analysis-response.json"
    TITLE=$(echo "$ANALYSIS_JSON" | "$JQ" -r '.title // "Voice Memo"' 2>/dev/null || echo "Voice Memo")
    SUMMARY=$(echo "$ANALYSIS_JSON" | "$JQ" -r '.summary // "Voice memo"' 2>/dev/null || echo "Voice memo")
    TAGS=$(echo "$ANALYSIS_JSON" | "$JQ" -c '.tags // ["voicememos"]' 2>/dev/null || echo '["voicememos"]')
    TODOS=$(echo "$ANALYSIS_JSON" | "$JQ" -c '.todos // []' 2>/dev/null || echo '[]')
fi

# Step 3: Condense transcript
log "Condensing transcript..."

# Read condense prompt from Obsidian (or use default)
if [[ -f "$PROMPTS_DIR/condense-prompt.md" ]]; then
    CONDENSE_PROMPT_BASE=$(cat "$PROMPTS_DIR/condense-prompt.md")
else
    CONDENSE_PROMPT_BASE="Condense this voice memo transcript into a sparse hierarchical markdown outline.

Output rules:
- Return ONLY valid markdown. No preamble.  No explanation. No enclosing \`\`\`markdown fence.
- Use exactly this structure:
  - HH:MM:SS - major topic phrase
    - HH:MM:SS - verb/subtopic phrase, verb/subtopic phrase
- Create a new top-level bullet ONLY when there is a clear major topic shift.
- Group nearby details under the same top-level bullet instead of creating a new heading for each timestamp.
- Use sub-bullets for minor points, examples, clarifications, instructions, reactions, or follow-up comments within the same topic.
- Keep top-level bullets rare.
- Prefer 5–12 top-level bullets total unless the transcript truly changes topic more often.
- Each bullet must be a fragment, not a full sentence.
- Keep each line short and compressed.
- Use concrete topic labels, not vague labels.

Do not use:
- \"discussion about\"
- \"conversation about\"
- \"they talked about\"
- \"important note\"
- \"feedback on\"
- \"thoughts on\"
- \"comments on\"
- full grammatical sentences

Compression rules:
- Merge adjacent transcript segments that serve the same subject, task, decision, story beat, question, reaction, or activity.
- Collapse repetitive wording, minor acknowledgements, filler, backchanneling, and small restatements unless they add new meaning.
- Fold examples, clarifications, objections, replies, and follow-ups into the same parent topic unless they clearly start a new one.
- Prefer fewer broader sections over many narrow ones.
- Start a new top-level bullet only when the speaker focus clearly changes to a different subject, goal, or interaction.
- Do not make a bullet for every timestamp.
- Omit low-information lines that do not materially change the summary.

Timestamp rules:
- Use the timestamp where the topic begins.
- Sub-bullets should use the timestamp where that sub-point begins.
- Do not invent timestamps.

Your first timestamp should be "00:00:00".

Transcript:
"
fi
CONDENSE_PROMPT="${CONDENSE_PROMPT_BASE}
$(cat "$TRANSCRIPTION_FILE")"

# Use jq to safely construct the JSON payload
CONDENSE_PAYLOAD=$("$JQ" -n \
    --arg model "$OLLAMA_MODEL" \
    --arg prompt "$CONDENSE_PROMPT" \
    '{
        model: $model,
        prompt: $prompt,
        stream: false
    }')

CONDENSE_FILE="$TEMP_DIR/condense.json"
curl -s -X POST \
    "${OLLAMA_ENDPOINT}/api/generate" \
    -H "Content-Type: application/json" \
    -d "$CONDENSE_PAYLOAD" -o "$CONDENSE_FILE" 2>/dev/null

CONDENSED_TRANSCRIPT=$("$JQ" -r '.response // empty' "$CONDENSE_FILE" 2>/dev/null)

rm -f "$CONFIG_DIR/last-condense-response.txt" "$CONFIG_DIR/last-condense-response-raw.json"
cp "$CONDENSE_FILE" "$CONFIG_DIR/last-condense-response-raw.json"

if [[ -z "$CONDENSED_TRANSCRIPT" ]]; then
    log "WARNING: Failed to condense transcript, using default"
    log "Condense response: $(cat "$CONDENSE_FILE")"
    CONDENSED_TRANSCRIPT="N/A"
else
    echo "$CONDENSED_TRANSCRIPT" > "$CONFIG_DIR/last-condense-response.txt"
fi

log "Analysis complete: $TITLE"

# Get current date info
TODAY=$(date '+%Y-%m-%d')
TIME=$(date '+%H:%M')

# Format tags for YAML frontmatter (as array)
TAGS_YAML=$(echo "$TAGS" | "$JQ" -r '.[] | "  - " + .' 2>/dev/null)
# Always include voicememos tag
if ! echo "$TAGS_YAML" | grep -q "voicememos"; then
    TAGS_YAML="  - voicememos
$TAGS_YAML"
fi

# Format todos - AI returns pre-formatted strings, just join with newlines
TODOS_MD=""
TODO_COUNT=$(echo "$TODOS" | "$JQ" 'length' 2>/dev/null || echo "0")
if [[ "$TODO_COUNT" -gt 0 ]]; then
    TODOS_MD="## Tasks

"
    TODOS_MD+=$(echo "$TODOS" | "$JQ" -r '.[]' 2>/dev/null)
    TODOS_MD+="

"
fi

# Get date/time for filename
TIMESTAMP_DATE=""
TIMESTAMP_TIME=""

# First choice: parse from filename (format: YYYYMMDD HHMMSS-...)
if [[ "$FILENAME" =~ '^([0-9]{8}) ([0-9]{6})-' ]]; then
    RAW_DATE="${match[1]}"
    RAW_TIME="${match[2]}"
    TIMESTAMP_DATE="${RAW_DATE:0:4}-${RAW_DATE:4:2}-${RAW_DATE:6:2}"
    TIMESTAMP_TIME="${RAW_TIME:0:2}:${RAW_TIME:2:2}:${RAW_TIME:4:2}"
else
    # Second choice: use newer of added/modified date
    FILE_MTIME_EPOCH=$(stat -f "%m" "$INPUT_FILE" 2>/dev/null || echo "")
    FILE_BTIME_EPOCH=$(stat -f "%B" "$INPUT_FILE" 2>/dev/null || echo "")

    if [[ -n "$FILE_MTIME_EPOCH" && -n "$FILE_BTIME_EPOCH" ]]; then
        if [[ "$FILE_MTIME_EPOCH" -ge "$FILE_BTIME_EPOCH" ]]; then
            FILE_TIME_EPOCH="$FILE_MTIME_EPOCH"
        else
            FILE_TIME_EPOCH="$FILE_BTIME_EPOCH"
        fi
    elif [[ -n "$FILE_MTIME_EPOCH" ]]; then
        FILE_TIME_EPOCH="$FILE_MTIME_EPOCH"
    elif [[ -n "$FILE_BTIME_EPOCH" ]]; then
        FILE_TIME_EPOCH="$FILE_BTIME_EPOCH"
    else
        FILE_TIME_EPOCH=""
    fi

    if [[ -n "$FILE_TIME_EPOCH" ]]; then
        TIMESTAMP_DATE=$(date -r "$FILE_TIME_EPOCH" '+%Y-%m-%d')
        TIMESTAMP_TIME=$(date -r "$FILE_TIME_EPOCH" '+%H:%M:%S')
    else
        # Third choice: use current date/time
        TIMESTAMP_DATE=$(date '+%Y-%m-%d')
        TIMESTAMP_TIME=$(date '+%H:%M:%S')
    fi
fi

# Format time for filename (example: pm 08,43,13)
HOUR_24=$(echo "$TIMESTAMP_TIME" | cut -d: -f1)
MINUTE=$(echo "$TIMESTAMP_TIME" | cut -d: -f2)
SECOND=$(echo "$TIMESTAMP_TIME" | cut -d: -f3)

if [[ "$HOUR_24" -lt 12 ]]; then
    TIME_PERIOD="am"
else
    TIME_PERIOD="pm"
fi

HOUR_12=$((10#$HOUR_24 % 12))
if [[ "$HOUR_12" -eq 0 ]]; then
    HOUR_12=12
fi

TIME_FOR_TITLE="${TIME_PERIOD} $(printf '%02d' "$HOUR_12"),${MINUTE},${SECOND}"

# Create safe filename from timestamp + title
SAFE_TITLE=$(echo "$TITLE" | sed 's/[\/:]/ /g' | sed 's/  */ /g' | sed 's/^ *//' | sed 's/ *$//')
BASE_TITLE="${TIMESTAMP_DATE} ${TIME_FOR_TITLE} - ${SAFE_TITLE}"

NOTE_FILENAME="${BASE_TITLE}.md"
NOTE_PATH="$VOICE_MEMOS_PATH/$NOTE_FILENAME"
VTT_FILENAME="${BASE_TITLE}.vtt"
VTT_PATH="$VOICE_MEMOS_PATH/$VTT_FILENAME"
AUDIO_FILENAME="${BASE_TITLE}.${FILENAME##*.}"
AUDIO_PATH="$VOICE_MEMOS_PATH/$AUDIO_FILENAME"

# Handle duplicate filenames
if [[ -f "$NOTE_PATH" || -f "$VTT_PATH" || -f "$AUDIO_PATH" ]]; then
    DUPLICATE_COUNT=2
    while true; do
        NOTE_FILENAME="${BASE_TITLE} ${DUPLICATE_COUNT}.md"
        NOTE_PATH="$VOICE_MEMOS_PATH/$NOTE_FILENAME"
        VTT_FILENAME="${BASE_TITLE} ${DUPLICATE_COUNT}.vtt"
        VTT_PATH="$VOICE_MEMOS_PATH/$VTT_FILENAME"
        AUDIO_FILENAME="${BASE_TITLE} ${DUPLICATE_COUNT}.${FILENAME##*.}"
        AUDIO_PATH="$VOICE_MEMOS_PATH/$AUDIO_FILENAME"

        if [[ ! -f "$NOTE_PATH" && ! -f "$VTT_PATH" && ! -f "$AUDIO_PATH" ]]; then
            break
        fi

        DUPLICATE_COUNT=$((DUPLICATE_COUNT + 1))
    done
fi

# Save the audio file
log "Saving audio: $AUDIO_PATH"
cp "$INPUT_FILE" "$AUDIO_PATH"

# Save the VTT file
log "Saving VTT: $VTT_PATH"
cp "$TRANSCRIPTION_FILE" "$VTT_PATH"

# Save audio title information
AUDIO_TITLE=$(
  ffprobe -v error \
    -show_entries format_tags=title \
    -of default=noprint_wrappers=1:nokey=1 \
    "$INPUT_FILE"
)
log "Audio title is $AUDIO_TITLE"


TRANSCRIPT_NO_NEWLINES=${TRANSCRIPT//$'\n'/}

# Create the note file
log "Creating note: $NOTE_PATH"
cat > "$NOTE_PATH" << MEMO
---
tags:
$TAGS_YAML
author:
  - "[[Me]]"
created: "${TODAY}"
time: "${TIME}"
audio_title: "${AUDIO_TITLE}"
status:
---

![[${AUDIO_FILENAME}]]
![[${VTT_FILENAME}]]

${TODOS_MD}## Summary

$SUMMARY

## Condensed transcript

$CONDENSED_TRANSCRIPT

## Transcript

$TRANSCRIPT_NO_NEWLINES
MEMO

# Mark as processed
touch "$PROCESSED_MARKER"

# Cleanup
rm -rf "$TEMP_DIR"

log "SUCCESS: Voice memo saved to $NOTE_PATH"

exit 0
