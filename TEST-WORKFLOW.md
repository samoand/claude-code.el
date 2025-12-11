# Claude Code Logging - Test Workflow

## Issue Fixed
The buffer snapshot was failing with "Args out of range" error when the terminal buffer shrank. This has been fixed to handle buffer size changes gracefully.

## Testing Steps

### 1. Reload the Fixed Code
```elisp
;; In your Emacs session:
M-x find-file RET ~/.emacs.d/git-installs/claude-code/claude-code-log.el RET
M-x eval-buffer

;; Load debug helper
M-x load-file RET ~/.emacs.d/git-installs/claude-code/claude-code-log-debug.el RET
```

### 2. Verify System Status
```elisp
M-x claude-code-log-debug-status
```

**Expected output:**
- Advice active: YES
- Event hook active: YES
- Configuration shows your settings
- Transaction state (if in Claude buffer)

### 3. Test Transaction Workflow

#### Start a new Claude session (if needed):
```elisp
M-x claude-code
```

#### Begin transaction:
```elisp
M-x claude-code-record
;; Message: "Transaction txn-XXXXXXXX-XXXX started"
```

#### Send commands properly (IMPORTANT):
**DO NOT** type directly in the buffer!

**DO** use one of these methods:
```elisp
;; Method 1: Using send-command function
M-x claude-code-send-command RET
Type your command: "test message for logging"

;; Method 2: Using the keybinding (if configured)
C-c c s  ;; then type your command
```

#### Test snapshot capture:
```elisp
M-x claude-code-log-test-snapshot
```

**Expected:**
- Message showing how many chars would be captured
- A "*Snapshot Test*" buffer showing the content
- NO "Args out of range" error

#### Commit transaction:
```elisp
M-x claude-code-commit
;; Prompt: Enter description (or accept default from first command)
```

#### Verify logs:
```bash
# Check the transaction was logged
cd ~/Projects/claude-data-corpus/projects/*/latest/raw-transactional/
ls -lt | head -5

# View the log content
cat txn-XXXXXXXX-*.log
```

**Expected in log file:**
```
TRANSACTION-START: txn-XXXXXXXX-XXXX
DESCRIPTION: test message for logging
TIMESTAMP: ...

USER-COMMAND: test message for logging
TIMESTAMP: ...

CONVERSATION-SNAPSHOT:
[Content of conversation should be here, not empty]

TRANSACTION-END
```

## Troubleshooting

### If "Advice active: NO"
```elisp
M-x claude-code-log-enable
M-x claude-code-log-debug-status  ;; verify now shows YES
```

### If conversation snapshot is still empty:
1. Verify you used `claude-code-send-command`, not direct typing
2. Check if Claude actually responded (wait for tool output)
3. Run `claude-code-log-test-snapshot` before commit to preview

### If buffer size error still occurs:
This should be fixed now - the code captures entire buffer if baseline point is invalid. Check debug status to see if warning message appears.

## Mode Line Indicator

The logging system adds a **visual indicator** to your mode line showing transaction status:

- **No indicator**: Not in a transaction
- **`[TXN:0]`**: Transaction active, 0 commands sent
- **`[TXN:3]`**: Transaction active, 3 commands sent
- **`[TXN:2→]`**: Transaction with parent link, 2 commands sent

**Hover over the indicator** (or check minibuffer) to see:
- Full transaction ID
- Command count
- Parent transaction ID (if linked)

This makes it easy to see at a glance if you're currently recording!

## Quick Commands Reference

| Command | Key | Purpose |
|---------|-----|---------|
| `claude-code-record` | `C-c l r` | Start transaction |
| `claude-code-commit` | `C-c l c` | Commit transaction |
| `claude-code-log-test-snapshot` | - | Preview what will be captured |
| `claude-code-log-debug-status` | - | Show system status |
| `claude-code-send-command` | `C-c c s` | Send command to Claude |

## Key Insight

**The logging system intercepts commands sent through `claude-code--do-send-command`.**

When you type directly in the buffer:
- ❌ Commands are NOT intercepted
- ❌ `claude-code-log--first-command` stays nil
- ❌ USER-COMMAND entries are NOT logged

When you use `claude-code-send-command`:
- ✅ Commands ARE intercepted
- ✅ First command is captured for description
- ✅ USER-COMMAND entries are logged properly

## Expected Behavior After Fix

1. **Buffer shrinks (terminal scrollback)**: System captures entire buffer with warning
2. **Commands sent properly**: All commands logged with timestamps
3. **Conversation captured**: Full exchange between user and Claude preserved
4. **Metadata generated**: JSON file with description, artifacts, timing
