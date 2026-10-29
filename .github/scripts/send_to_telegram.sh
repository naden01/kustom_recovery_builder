#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────
#  $1  MODE            "notify" | "release"
#  $2  DEVICE
#  $3  BRANCH
#  $4  BUILD_DATE      (release only)
#  $5  COMMIT_ID       (release only)
#  $6  RELEASE_URL     (release only)
#  $7  DEVICE_TREE     (release only)
#  $8  CHAT_ID
#  $9  TOKEN
#  $10 WORKFLOW_NAME
#  $11 WORKFLOW_RUN_URL
#  $12 GITHUB_TOKEN    (release only)
#  $13 REPO            (release only)
#  $14 RUN_ID          (release only)
# ─────────────────────────────────────────────────────────────

MODE="$1"
DEVICE="$2"
BRANCH="$3"
BUILD_DATE="$4"
COMMIT_ID="$5"
RELEASE_URL="$6"
DEVICE_TREE="$7"
CHAT_ID="$8"
TOKEN="$9"
WORKFLOW_NAME="${10}"
WORKFLOW_RUN_URL="${11}"
GITHUB_TOKEN="${12}"
REPO="${13}"
RUN_ID="${14}"

# ─────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────
escape_md() {
  printf '%s' "$1" | sed 's/[_*\[\]()~`>#+\-=|{}.!\\]/\\&/g'
}

send_message() {
  local TEXT="$1"
  RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    --data-urlencode text="$TEXT" \
    -d parse_mode="MarkdownV2")
  echo "Telegram response: $RESPONSE"
  if echo "$RESPONSE" | grep -q '"ok":false'; then
    echo "❌ Failed to send Telegram message"
    exit 1
  fi
}

send_file() {
  local FILE_PATH="$1"
  local CAPTION="$2"

  if [[ ! -f "$FILE_PATH" ]]; then
    echo "⚠️ Skipping: $FILE_PATH (not found)"
    return 0
  fi

  local SIZE
  SIZE=$(stat -c%s "$FILE_PATH" 2>/dev/null || stat -f%z "$FILE_PATH")

  if (( SIZE > 50000000 )); then
    echo "⚠️ $FILE_PATH exceeds 50 MB — splitting"
    split -b 45M "$FILE_PATH" "${FILE_PATH}.part_"
    local PART_NUM=1
    for PART in "${FILE_PATH}.part_"*; do
      send_file "$PART" "${CAPTION} (part ${PART_NUM})"
      PART_NUM=$(( PART_NUM + 1 ))
    done
    rm -f "${FILE_PATH}.part_"*
    return 0
  fi

  echo "📤 Uploading: $FILE_PATH ($(( SIZE / 1024 )) KB)"
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendDocument" \
    -F chat_id="${CHAT_ID}" \
    -F document=@"${FILE_PATH}" \
    -F caption="${CAPTION}" \
    -F parse_mode="MarkdownV2"
}

download_github_logs() {
  local OUT_ZIP="/tmp/run_logs.zip"
  local OUT_DIR="/tmp/run_logs"
  local MERGED="/tmp/workflow_build.log"
  local ERR_BODY="/tmp/logs_api_error.json"

  echo "📥 Downloading workflow logs from GitHub API..."
  echo "   Repo: ${REPO}  Run: ${RUN_ID}"

  HTTP_STATUS=$(curl -s -w "%{http_code}" -o "$OUT_ZIP" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -L "https://api.github.com/repos/${REPO}/actions/runs/${RUN_ID}/logs")

  echo "   GitHub API HTTP status: $HTTP_STATUS"

  if [[ "$HTTP_STATUS" != "200" ]]; then
    # The response body (error JSON) was written to OUT_ZIP — print it
    echo "⚠️ Failed to download logs:"
    cat "$OUT_ZIP" || true
    return 0   # non-fatal — message was already sent, just skip the file
  fi

  # Verify it's actually a zip
  if ! file "$OUT_ZIP" | grep -q "Zip"; then
    echo "⚠️ Downloaded file is not a zip:"
    cat "$OUT_ZIP" || true
    return 0
  fi

  mkdir -p "$OUT_DIR"
  unzip -q "$OUT_ZIP" -d "$OUT_DIR"

  # Merge all step logs sorted by name (step order)
  find "$OUT_DIR" -name "*.txt" | sort -t_ -k1,1n | while IFS= read -r f; do { echo "===== $(basename "$f") ====="; cat "$f"; echo; }; done > "$MERGED"

  local MERGED_SIZE
  MERGED_SIZE=$(stat -c%s "$MERGED" 2>/dev/null || stat -f%z "$MERGED")
  echo "   Merged log size: $(( MERGED_SIZE / 1024 )) KB"

  echo "$MERGED"
}

# ─────────────────────────────────────────────
#  Validate
# ─────────────────────────────────────────────
if [[ -z "$CHAT_ID" || -z "$TOKEN" ]]; then
  echo "❌ CHAT_ID or TOKEN is empty — check argument positions!"
  exit 1
fi

echo "🔍 Debug: MODE=$MODE DEVICE=$DEVICE BRANCH=$BRANCH CHAT_ID=[set] TOKEN=[set]"

# ─────────────────────────────────────────────
#  MODE: notify
# ─────────────────────────────────────────────
if [[ "$MODE" == "notify" ]]; then
  text=$(cat << EOF
⚙️ *Build Started*
📋 *Workflow*: \`$(escape_md "${WORKFLOW_NAME}")\`
📱 *Device*: \`$(escape_md "${DEVICE}")\`
🌿 *Branch*: \`$(escape_md "${BRANCH}")\`
🔍 [Watch on GitHub Actions](${WORKFLOW_RUN_URL})
EOF
)
  send_message "$text"
  echo "✅ Start notification sent."
  exit 0
fi

# ─────────────────────────────────────────────
#  MODE: release
# ─────────────────────────────────────────────
if [[ "$MODE" == "release" ]]; then
  CLEAN_TREE=$(printf '%s' "${DEVICE_TREE}" | sed -e 's#/$##' -e 's#\.git$##' -e 's#/$##')
  if [[ -n "$CLEAN_TREE" ]]; then
    COMMIT_LINE="📝 *Commit*: [${COMMIT_ID:0:7}](${CLEAN_TREE}/commit/${COMMIT_ID})"
    TREE_LINE="🌳 *Tree*: [${CLEAN_TREE##*/}](${CLEAN_TREE}/tree/${BRANCH})"
  else
    COMMIT_LINE="📝 *Commit*: \`${COMMIT_ID:0:7}\`"
    TREE_LINE=""
  fi

  text=$(cat << EOF
🚀 *Unofficial Custom Recovery Build Released*
📋 *Workflow*: \`$(escape_md "${WORKFLOW_NAME}")\`
📱 *Device*: \`$(escape_md "${DEVICE}")\`
🌿 *Branch*: \`$(escape_md "${BRANCH}")\`
📅 *Build Date*: \`$(escape_md "${BUILD_DATE}")\`
${COMMIT_LINE}
${TREE_LINE}
🔗 [View Release on GitHub](${RELEASE_URL})
🪵 [Full Workflow Log](${WORKFLOW_RUN_URL})
EOF
)
  send_message "$text"

  # Download logs — runs in subshell so set -e won't kill us on failure
  LOG_FILE=$(download_github_logs) || true
  if [[ -f "$LOG_FILE" ]]; then
    LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE")
    if (( LOG_SIZE > 25000000 )); then
      echo "⚠️ Log is $(( LOG_SIZE / 1048576 )) MB — sending the last 3000 lines instead"
      tail -n 3000 "$LOG_FILE" > /tmp/workflow_build_tail.log
      send_file "/tmp/workflow_build_tail.log" "🪵 *Log tail* \`$(escape_md "${DEVICE}")\` (last 3000 lines) — [full run](${WORKFLOW_RUN_URL})"
    else
      send_file "$LOG_FILE" "🪵 *Workflow Log* \`$(escape_md "${DEVICE}")\`"
    fi
  else
    echo "⚠️ Log file not available — skipping upload."
  fi

  echo "✅ Release notification sent."
  exit 0
fi

echo "❌ Unknown mode: '$MODE'. Use 'notify' or 'release'."
exit 1
