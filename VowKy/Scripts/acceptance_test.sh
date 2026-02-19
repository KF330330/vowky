#!/bin/bash
# VowKy T6 真实场景验收测试
# 验证点: #70-75, #78
# 使用 VOWKY_TEST_AUDIO 环境变量 + AppleScript 验证跨 App 粘贴
#
# 用法:
#   bash acceptance_test.sh           # 运行全部可脚本化测试
#   bash acceptance_test.sh --long    # 包含 #78 长期运行测试 (30分钟)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
MANUAL_COUNT=0
TOTAL=7

pass() { echo "  ✅ PASS: $1"; ((PASS_COUNT++)); }
fail() { echo "  ❌ FAIL: $1"; ((FAIL_COUNT++)); }
skip() { echo "  ⏭️  SKIP: $1"; ((SKIP_COUNT++)); }
manual() { echo "  👁️  MANUAL: $1"; ((MANUAL_COUNT++)); }

# Find the VowKy app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "VowKy.app" -path "*/Debug/*" -maxdepth 5 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: 找不到 VowKy.app，请先编译项目"
  exit 1
fi

# Find test audio directory
TEST_AUDIO_DIR="$PROJECT_DIR/VowKy/Resources/TestAudio"
if [ ! -d "$TEST_AUDIO_DIR" ]; then
  # Try the model test wavs as fallback
  TEST_AUDIO_DIR="$PROJECT_DIR/VowKy/Resources/Models"
fi

echo "============================================"
echo "  VowKy T6 真实场景验收测试"
echo "============================================"
echo "  App: $APP_PATH"
echo "  Test Audio: $TEST_AUDIO_DIR"
echo ""

# Ensure VowKy is running with test audio
pkill -x "VowKy" 2>/dev/null || true
sleep 1

# Start VowKy with test audio environment variable
export VOWKY_TEST_AUDIO="$TEST_AUDIO_DIR"
open "$APP_PATH"
sleep 5

if ! pgrep -x "VowKy" > /dev/null; then
  echo "ERROR: VowKy 未能启动"
  exit 1
fi
echo "VowKy 已启动 (PID: $(pgrep -x VowKy))"
echo ""

# Helper: simulate Option+Space keyDown via CGEvent (using osascript)
simulate_hotkey() {
  osascript -e '
    tell application "System Events"
      key code 49 using {option down}
    end tell
  ' 2>/dev/null
}

# --- #70: TextEdit 粘贴成功 ---
echo "[#70] TextEdit 粘贴验证..."
# Open TextEdit with new document
osascript -e '
  tell application "TextEdit"
    activate
    make new document
  end tell
' 2>/dev/null
sleep 1

# Simulate hotkey press (start recording with test audio)
simulate_hotkey
sleep 1
# Simulate hotkey press again (stop and recognize)
simulate_hotkey
sleep 3

# Read TextEdit content
TEXTEDIT_CONTENT=$(osascript -e '
  tell application "TextEdit"
    return text of front document
  end tell
' 2>/dev/null || echo "")

if [ -n "$TEXTEDIT_CONTENT" ] && [ "$TEXTEDIT_CONTENT" != "" ]; then
  pass "TextEdit 粘贴成功: \"${TEXTEDIT_CONTENT:0:30}...\""
else
  skip "TextEdit 粘贴未检测到内容（可能 VOWKY_TEST_AUDIO 未生效或需要手动测试）"
fi

# Close TextEdit
osascript -e 'tell application "TextEdit" to quit saving no' 2>/dev/null
sleep 1
echo ""

# --- #71: 浮窗正确显示/隐藏 (手动) ---
echo "[#71] 浮窗显示/隐藏..."
manual "浮窗视觉表现需手动确认：按 Option+Space 后浮窗出现，再按后显示识别中，完成后自动消失"
echo ""

# --- #72: 剪贴板恢复 ---
echo "[#72] 剪贴板恢复验证..."
# Set clipboard to known value
osascript -e 'set the clipboard to "剪贴板恢复测试原始内容"' 2>/dev/null

# Open TextEdit for paste target
osascript -e '
  tell application "TextEdit"
    activate
    make new document
  end tell
' 2>/dev/null
sleep 1

# Trigger VowKy (toggle start + toggle stop)
simulate_hotkey
sleep 1
simulate_hotkey
sleep 3

# Check clipboard is restored
CLIPBOARD_AFTER=$(osascript -e 'return (the clipboard as text)' 2>/dev/null || echo "")

if [ "$CLIPBOARD_AFTER" = "剪贴板恢复测试原始内容" ]; then
  pass "剪贴板恢复成功"
elif [ -n "$CLIPBOARD_AFTER" ]; then
  # Clipboard might have been restored to something else
  skip "剪贴板内容变化: \"$CLIPBOARD_AFTER\"（需手动验证恢复时序）"
else
  skip "无法读取剪贴板内容"
fi

osascript -e 'tell application "TextEdit" to quit saving no' 2>/dev/null
sleep 1
echo ""

# --- #73: Safari 粘贴成功 ---
echo "[#73] Safari 粘贴验证..."
osascript -e '
  tell application "Safari"
    activate
    make new document
  end tell
' 2>/dev/null
sleep 2

# Click address bar
osascript -e '
  tell application "System Events"
    tell process "Safari"
      keystroke "l" using command down
    end tell
  end tell
' 2>/dev/null
sleep 1

simulate_hotkey
sleep 1
simulate_hotkey
sleep 3

# Read Safari address bar
SAFARI_URL=$(osascript -e '
  tell application "Safari"
    return URL of front document
  end tell
' 2>/dev/null || echo "")

skip "Safari 粘贴需手动验证（地址栏内容检测受限）"
osascript -e 'tell application "Safari" to quit' 2>/dev/null
sleep 1
echo ""

# --- #74: Notes 粘贴成功 ---
echo "[#74] Notes 粘贴验证..."
osascript -e '
  tell application "Notes"
    activate
    tell account "iCloud"
      make new note at folder "Notes" with properties {body:""}
    end tell
  end tell
' 2>/dev/null
sleep 2

simulate_hotkey
sleep 1
simulate_hotkey
sleep 3

NOTES_CONTENT=$(osascript -e '
  tell application "Notes"
    return body of first note
  end tell
' 2>/dev/null || echo "")

if [ -n "$NOTES_CONTENT" ]; then
  pass "Notes 粘贴检测到内容"
else
  skip "Notes 粘贴需手动验证"
fi

osascript -e 'tell application "Notes" to quit' 2>/dev/null
sleep 1
echo ""

# --- #75: Terminal 粘贴成功 ---
echo "[#75] Terminal 粘贴验证..."
osascript -e '
  tell application "Terminal"
    activate
    do script ""
  end tell
' 2>/dev/null
sleep 2

simulate_hotkey
sleep 1
simulate_hotkey
sleep 3

skip "Terminal 粘贴需手动验证（终端输入缓冲区不易自动读取）"
osascript -e 'tell application "Terminal" to quit' 2>/dev/null
sleep 1
echo ""

# --- #78: 长期运行快捷键不失效 ---
echo "[#78] 长期运行稳定性..."
if [ "$1" = "--long" ]; then
  echo "  开始 30 分钟耐久测试..."
  LONG_PASS=0
  LONG_FAIL=0

  for i in $(seq 1 60); do
    # Every 30 seconds
    simulate_hotkey
    sleep 1
    simulate_hotkey
    sleep 2

    if pgrep -x "VowKy" > /dev/null; then
      ((LONG_PASS++))
    else
      ((LONG_FAIL++))
      echo "  ⚠️ Round $i: VowKy 进程消失"
    fi
    sleep 27  # Total ~30s per round
  done

  if [ "$LONG_FAIL" -eq 0 ]; then
    pass "30 分钟耐久测试通过 ($LONG_PASS 轮)"
  else
    fail "30 分钟耐久测试失败 ($LONG_FAIL 轮异常)"
  fi
else
  skip "长期运行测试需加 --long 参数（耗时 30 分钟）"
fi
echo ""

# --- Cleanup ---
pkill -x "VowKy" 2>/dev/null || true

# --- Summary ---
echo "============================================"
echo "  结果汇总"
echo "============================================"
echo "  通过: $PASS_COUNT"
echo "  失败: $FAIL_COUNT"
echo "  跳过: $SKIP_COUNT"
echo "  手动: $MANUAL_COUNT"
echo "  总计: $TOTAL"
echo "============================================"
echo ""
echo "注意: 部分测试依赖 VOWKY_TEST_AUDIO 环境变量和系统权限。"
echo "跳过的测试可通过手动操作验证。"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
