;;; claude-code-log-debug.el --- Debug helpers for claude-code-log -*- lexical-binding: t; -*-

;;; Code:

(require 'claude-code-log)

;;;###autoload
(defun claude-code-log-debug-status ()
  "Show current logging status and configuration."
  (interactive)
  (let ((output-buffer (get-buffer-create "*Claude Log Debug*")))
    (with-current-buffer output-buffer
      (erase-buffer)
      (insert "=== Claude Code Logging Debug Info ===\n\n")

      ;; Check if advice is active
      (insert (format "Advice active: %s\n"
                     (if (advice-member-p #'claude-code-log--wrap-send-command
                                         'claude-code--do-send-command)
                         "YES"
                       "NO - PROBLEM!")))

      ;; Check if event hook is active
      (insert (format "Event hook active: %s\n"
                     (if (member #'claude-code-log--event-listener
                                claude-code-event-hook)
                         "YES"
                       "NO - PROBLEM!")))

      ;; Configuration
      (insert (format "\nConfiguration:\n"))
      (insert (format "  claude-code-log: %s\n" claude-code-log))
      (insert (format "  Corpus dir: %s\n" claude-code-log-corpus-dir))
      (insert (format "  Clean tree: %s\n" claude-code-log-require-clean-tree))

      ;; Current transaction state
      (insert (format "\nCurrent Buffer Transaction State:\n"))
      (if (boundp 'claude-code-log--transaction-id)
          (progn
            (insert (format "  Transaction ID: %s\n"
                           (or claude-code-log--transaction-id "NONE")))
            (insert (format "  Baseline point: %s\n"
                           (or claude-code-log--baseline-buffer-point "N/A")))
            (insert (format "  Commands sent: %s\n"
                           (or claude-code-log--command-count 0)))
            (insert (format "  First command: %s\n"
                           (or claude-code-log--first-command "N/A")))
            (insert (format "  Parent transaction: %s\n"
                           (or claude-code-log--parent-transaction "NONE")))
            (insert (format "  Mode line indicator: %s\n"
                           (if claude-code-log--mode-line-indicator
                               (substring-no-properties claude-code-log--mode-line-indicator)
                             "NOT SET"))))
        (insert "  Not in a Claude buffer\n"))

      ;; Buffer info
      (insert (format "\nCurrent Buffer Info:\n"))
      (insert (format "  Name: %s\n" (buffer-name)))
      (insert (format "  Mode: %s\n" major-mode))
      (insert (format "  Size: %d chars\n" (buffer-size)))
      (insert (format "  Point: %d\n" (point)))
      (insert (format "  Point-max: %d\n" (point-max))))

    (display-buffer output-buffer)))

;;;###autoload
(defun claude-code-log-test-snapshot ()
  "Test what would be captured in a snapshot right now."
  (interactive)
  (if (not claude-code-log--transaction-id)
      (message "Not in a transaction!")
    (let* ((start-point claude-code-log--baseline-buffer-point)
           (end-point (point-max))
           (content (buffer-substring-no-properties start-point end-point)))
      (message "Would capture %d chars from %d to %d"
               (length content) start-point end-point)
      (with-current-buffer (get-buffer-create "*Snapshot Test*")
        (erase-buffer)
        (insert content)
        (display-buffer (current-buffer))))))

(provide 'claude-code-log-debug)
;;; claude-code-log-debug.el ends here
