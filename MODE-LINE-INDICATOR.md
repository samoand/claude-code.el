# Mode Line Transaction Indicator

## Overview

The Claude Code logging system now includes a **visual mode line indicator** that shows your current transaction status at a glance.

## What It Shows

### Visual States

- **No indicator**: Not currently in a transaction
- **`[TXN:0]`**: Transaction active, no commands sent yet
- **`[TXN:3]`**: Transaction active, 3 commands have been sent
- **`[TXN:2→]`**: Transaction linked to parent, 2 commands sent (the arrow indicates a parent link)

### Tooltip Information

Hover over the indicator (or check the help-echo in minibuffer) to see:
- Full transaction ID
- Total command count
- Parent transaction ID (if the transaction is linked)

Example tooltip:
```
Transaction: txn-20251209-143022-a3f8d912
Commands: 3
Linked to: txn-20251209-120000-xyz
```

## Implementation Details

### When Updated

The mode line indicator updates automatically when you:
1. **Start a transaction** (`claude-code-record`) - Shows `[TXN:0]`
2. **Send a command** (`claude-code-send-command`) - Increments counter `[TXN:1]`, `[TXN:2]`, etc.
3. **Link to parent** (`claude-code-link-to-parent`) - Adds arrow `[TXN:2→]`
4. **Start with parent** (`claude-code-record-with-parent`) - Shows arrow from start
5. **Commit transaction** (`claude-code-commit`) - Indicator disappears
6. **Reopen transaction** (`claude-code-reopen`) - Restores indicator with command count

### Technical Implementation

**Location**: Right side of mode line (appended to `mode-line-format`)

**Variable**: `claude-code-log--mode-line-indicator` (buffer-local)

**Update function**: `claude-code-log--update-mode-line`
- Called after state changes (record, commit, send command, link)
- Uses `success` face (typically green)
- Includes help-echo tooltip

**Setup**: Automatically added to new Claude Code buffers via `claude-code-start-hook`

## Usage Tips

1. **Quick status check**: Glance at mode line instead of running debug command
2. **Prevent accidental commits**: See at a glance if you're recording
3. **Command tracking**: Watch the counter increment as you work
4. **Parent awareness**: Arrow indicator reminds you this is a linked transaction

## Example Workflow

```
# Start a transaction
M-x claude-code-record
# Mode line shows: [TXN:0]

# Send first command
M-x claude-code-send-command RET "implement user login"
# Mode line shows: [TXN:1]

# Send second command
M-x claude-code-send-command RET "add error handling"
# Mode line shows: [TXN:2]

# Link to parent transaction
M-x claude-code-link-to-parent
# Mode line shows: [TXN:2→]

# Commit transaction
M-x claude-code-commit
# Mode line shows: (nothing - indicator cleared)
```

## Debugging

If the indicator is not showing:

1. Check if logging is enabled:
   ```elisp
   M-x claude-code-log-debug-status
   ```
   Should show "Event hook active: YES"

2. Check if mode line was added:
   ```elisp
   M-: (member 'claude-code-log--mode-line-indicator mode-line-format)
   ```
   Should return non-nil

3. Manually add to current buffer:
   ```elisp
   M-x eval-expression RET (claude-code-log--setup-mode-line)
   ```

4. Re-enable logging system:
   ```elisp
   M-x claude-code-log-disable
   M-x claude-code-log-enable
   ```

## Code Reference

**Main files**:
- `claude-code-log.el:127-150` - Indicator definition and update function
- `claude-code-log.el:1074-1078` - Setup function
- `claude-code-log.el:1080-1094` - Enable function with hook registration

**Key functions**:
- `claude-code-log--update-mode-line` - Updates indicator text and tooltip
- `claude-code-log--setup-mode-line` - Adds indicator to mode line format
- Called from: record, commit, reopen, wrap-send-command, link functions
