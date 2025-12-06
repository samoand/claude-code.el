;;; claude-code-log.el --- Logging system for Claude Code interactions -*- lexical-binding: t; -*-

;; Author: Andrew
;; Version: 1.0.0
;; Package-Requires: ((emacs "30.0") (claude-code "0.4.5"))
;; Keywords: tools, ai, logging
;; URL: https://github.com/stevemolitor/claude-code.el

;;; Commentary:
;; This package provides comprehensive logging of Claude Code interactions
;; for building RAG (Retrieval-Augmented Generation) training data.
;;
;; Features:
;; - Dual-mode logging: transactional (high-value) and standalone (background)
;; - Per-buffer transaction state
;; - Git-aware artifact tracking
;; - Conversation capture and metadata generation
;;
;; Usage:
;;   M-x claude-code-record  ; Start transaction
;;   M-x claude-code-commit  ; End transaction
;;
;; See DESIGN.md for full documentation.

;;; Code:

(require 'claude-code)
(require 'project)
(require 'json)

;;;; Customization

(defgroup claude-code-log nil
  "Logging system for Claude Code interactions."
  :group 'claude-code
  :prefix "claude-code-log-")

(defcustom claude-code-log t
  "Enable Claude non-transactional logging.
When nil, only transactional logging (claude-record/commit) occurs.
When t, both transactional and standalone logging are enabled."
  :type 'boolean
  :group 'claude-code-log)

(defcustom claude-code-log-corpus-dir
  (expand-file-name "~/Projects/claude-data-corpus")
  "Root directory for Claude data corpus."
  :type 'directory
  :group 'claude-code-log)

(defcustom claude-code-log-require-clean-tree 'prompt
  "How to handle uncommitted changes at transaction start.
- prompt: Ask user (default)
- auto-commit: Automatically commit with baseline message
- error: Refuse to start transaction
- allow: Allow dirty tree, track carefully"
  :type '(choice (const :tag "Prompt user" prompt)
                 (const :tag "Auto-commit" auto-commit)
                 (const :tag "Error on dirty" error)
                 (const :tag "Allow dirty tree" allow))
  :group 'claude-code-log)

(defcustom claude-code-log-artifact-detection 'git
  "Method for detecting artifacts.
- git: Use git diff (recommended)
- none: Disable artifact tracking"
  :type '(choice (const :tag "Git-based" git)
                 (const :tag "Disabled" none))
  :group 'claude-code-log)

(defcustom claude-code-log-wait-timeout 60
  "Seconds to wait for Claude to finish before commit timeout."
  :type 'integer
  :group 'claude-code-log)

;;;; Variables

(defvar claude-code-log--enabled-internal t
  "Internal flag for temporarily disabling logging.
Use `claude-code-log' for user-facing control.")

(defvar-local claude-code-log--transaction-id nil
  "Current transaction ID, or nil if not in transaction.")

(defvar-local claude-code-log--baseline-sha nil
  "Git HEAD SHA at transaction start.")

(defvar-local claude-code-log--baseline-timestamp nil
  "Transaction start timestamp.")

(defvar-local claude-code-log--baseline-buffer-point nil
  "Buffer position at transaction start.")

(defvar-local claude-code-log--baseline-dirty-files nil
  "List of dirty files at transaction start.")

(defvar-local claude-code-log--artifact-tracking t
  "Whether artifact tracking is enabled for this buffer.")

(defvar-local claude-code-log--tool-uses nil
  "List of tool uses during current transaction.")

(defvar-local claude-code-log--command-count 0
  "Number of commands sent during current transaction.")

(defvar-local claude-code-log--waiting-for-finish nil
  "Non-nil when waiting for Claude to finish responding.")

(defvar-local claude-code-log--description nil
  "User-provided description for current transaction.")

(defvar-local claude-code-log--parent-transaction nil
  "Parent transaction ID for current transaction.")

(defvar-local claude-code-log--relationship-type nil
  "Relationship type to parent (parent-child, follows, related).")

(defvar-local claude-code-log--related-transactions nil
  "List of related transaction IDs.")

(defvar-local claude-code-log--first-command nil
  "First command sent in transaction (for auto description).")

(defvar claude-code-log--parent-history nil
  "History for parent transaction selection.")

;;;; Utility Functions

(defun claude-code-log--timestamp ()
  "Generate ISO 8601 timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%S"))

(defun claude-code-log--date ()
  "Generate date string for daily logs."
  (format-time-string "%Y-%m-%d"))

(defun claude-code-log--generate-transaction-id ()
  "Generate unique transaction ID."
  (format "txn-%s-%s"
          (format-time-string "%Y%m%d-%H%M%S")
          (substring (md5 (format "%s%s" (random) (current-time))) 0 8)))

(defun claude-code-log--get-project-name ()
  "Get current project name or \\='unclassified\\='."
  (if-let* ((proj (project-current))
            (root (project-root proj))
            (name (file-name-nondirectory
                   (directory-file-name root))))
      name
    "unclassified"))

(defun claude-code-log--get-version-dir (project)
  "Get version directory for PROJECT by resolving \\='latest\\=' symlink."
  (let* ((project-dir (expand-file-name
                       (concat "projects/" project)
                       claude-code-log-corpus-dir))
         (latest-link (expand-file-name "latest" project-dir)))
    (if (file-symlink-p latest-link)
        (expand-file-name (file-symlink-p latest-link) project-dir)
      ;; Fallback to v1 if no symlink exists
      (let ((v1-dir (expand-file-name "v1" project-dir)))
        (unless (file-directory-p v1-dir)
          (make-directory v1-dir t))
        v1-dir))))

(defun claude-code-log--ensure-directories (project)
  "Ensure all logging directories exist for PROJECT."
  (let* ((version-dir (claude-code-log--get-version-dir project))
         (subdirs '("artifacts-transactional"
                    "artifacts-standalone"
                    "metadata"
                    "raw-transactional"
                    "raw-standalone"
                    "samples")))
    (dolist (subdir subdirs)
      (let ((dir (expand-file-name subdir version-dir)))
        (unless (file-directory-p dir)
          (make-directory dir t))))))

(defun claude-code-log--in-git-repo-p ()
  "Check if current directory is in a git repository."
  (= 0 (call-process "git" nil nil nil "rev-parse" "--git-dir")))

(defun claude-code-log--get-git-sha ()
  "Get current git HEAD SHA, or nil if not in git repo."
  (when (claude-code-log--in-git-repo-p)
    (string-trim (shell-command-to-string "git rev-parse HEAD"))))

(defun claude-code-log--get-dirty-files ()
  "Get list of currently dirty files (modified, staged, untracked).
Returns list of relative file paths."
  (when (claude-code-log--in-git-repo-p)
    (let* ((modified (shell-command-to-string "git diff --name-only"))
           (staged (shell-command-to-string "git diff --cached --name-only"))
           (untracked (shell-command-to-string
                       "git ls-files --others --exclude-standard")))
      (delete-dups
       (append (split-string modified "\n" t)
               (split-string staged "\n" t)
               (split-string untracked "\n" t))))))

(defun claude-code-log--tree-is-clean-p ()
  "Check if git working tree is clean."
  (null (claude-code-log--get-dirty-files)))

;;;; File Writing Functions

(defun claude-code-log--write-to-file (file-path content &optional append)
  "Write CONTENT to FILE-PATH.
If APPEND is non-nil, append to file instead of overwriting."
  (let ((dir (file-name-directory file-path)))
    (unless (file-directory-p dir)
      (make-directory dir t)))
  (with-temp-buffer
    (insert content)
    (if append
        (append-to-file (point-min) (point-max) file-path)
      (write-region (point-min) (point-max) file-path))))

(defun claude-code-log--get-log-file (project transaction-id log-type)
  "Get log file path for PROJECT.
TRANSACTION-ID is used for transactional logs.
LOG-TYPE is either \\='transactional or \\='standalone."
  (let* ((version-dir (claude-code-log--get-version-dir project))
         (subdir (if (eq log-type 'transactional)
                     "raw-transactional"
                   "raw-standalone"))
         (filename (if (eq log-type 'transactional)
                       (format "%s.log" transaction-id)
                     (format "%s.log" (claude-code-log--date)))))
    (expand-file-name filename (expand-file-name subdir version-dir))))

(defun claude-code-log--write-transaction-start (project transaction-id buffer-name git-sha)
  "Write transaction start marker.
PROJECT is the project name.
TRANSACTION-ID is the transaction ID.
BUFFER-NAME is the Claude buffer name.
GIT-SHA is the baseline git SHA (or nil)."
  (let* ((log-file (claude-code-log--get-log-file project transaction-id 'transactional))
         (timestamp (claude-code-log--timestamp))
         (version "v1") ; TODO: resolve from symlink
         (content (format ";;; TRANSACTION-START: %s | %s | buffer: %s\n;;; PROJECT: %s | VERSION: %s | GIT-SHA: %s\n\n"
                          transaction-id
                          timestamp
                          buffer-name
                          project
                          version
                          (or git-sha "N/A"))))
    (claude-code-log--write-to-file log-file content)))

(defun claude-code-log--write-transaction-end (project transaction-id duration artifact-count)
  "Write transaction end marker.
PROJECT is the project name.
TRANSACTION-ID is the transaction ID.
DURATION is transaction duration in seconds.
ARTIFACT-COUNT is number of artifacts captured."
  (let* ((log-file (claude-code-log--get-log-file project transaction-id 'transactional))
         (timestamp (claude-code-log--timestamp))
         (duration-str (format "%dm%ds"
                               (/ duration 60)
                               (mod duration 60)))
         (content (format "\n;;; TRANSACTION-END: %s | %s | duration: %s | artifacts: %d\n"
                          transaction-id
                          timestamp
                          duration-str
                          artifact-count)))
    (claude-code-log--write-to-file log-file content t)))

(defun claude-code-log--write-command (project transaction-id log-type cmd)
  "Write user command to log.
PROJECT is the project name.
TRANSACTION-ID is the transaction ID (or nil for standalone).
LOG-TYPE is either \\='transactional or \\='standalone.
CMD is the command string."
  (let* ((log-file (claude-code-log--get-log-file project transaction-id log-type))
         (timestamp (claude-code-log--timestamp))
         (content (format ">>> USER-COMMAND | %s\n%s\n\n"
                          timestamp
                          cmd)))
    (claude-code-log--write-to-file log-file content t)))

(defun claude-code-log--write-tool-use (project transaction-id tool-type tool-data)
  "Write tool use marker to log.
PROJECT is the project name.
TRANSACTION-ID is the transaction ID.
TOOL-TYPE is the tool name (e.g., Read, Edit).
TOOL-DATA is additional tool information (e.g., file path)."
  (let* ((log-file (claude-code-log--get-log-file project transaction-id 'transactional))
         (timestamp (claude-code-log--timestamp))
         (content (format ";;; TOOL-USE: %s | %s\n%s\n\n"
                          tool-type
                          timestamp
                          tool-data)))
    (claude-code-log--write-to-file log-file content t)))

(defun claude-code-log--write-conversation-snapshot (project transaction-id conversation)
  "Write conversation snapshot to log.
PROJECT is the project name.
TRANSACTION-ID is the transaction ID.
CONVERSATION is the buffer content string."
  (let ((log-file (claude-code-log--get-log-file project transaction-id 'transactional)))
    (claude-code-log--write-to-file log-file
                                    (format "\n;;; CONVERSATION-SNAPSHOT | %s\n%s\n\n"
                                            (claude-code-log--timestamp)
                                            conversation)
                                    t)))

(defun claude-code-log--write-continuation-marker (project transaction-id)
  "Write transaction reopened marker.
PROJECT is the project name.
TRANSACTION-ID is the transaction ID."
  (let* ((log-file (claude-code-log--get-log-file project transaction-id 'transactional))
         (timestamp (claude-code-log--timestamp))
         (content (format "\n;;; TRANSACTION-REOPENED: %s | %s\n;;; Reason: User continuation\n\n"
                          transaction-id
                          timestamp)))
    (claude-code-log--write-to-file log-file content t)))

;;;; Git Artifact Functions

(defun claude-code-log--get-artifacts (baseline-dirty-files)
  "Get list of artifacts (changed files) since transaction start.
BASELINE-DIRTY-FILES is list of files that were dirty at start.
Returns list of file paths."
  (when (and (claude-code-log--in-git-repo-p)
             (eq claude-code-log-artifact-detection 'git))
    (let* ((modified (shell-command-to-string "git diff --name-only HEAD"))
           (untracked (shell-command-to-string
                       "git ls-files --others --exclude-standard"))
           (all-changes (delete-dups
                         (append (split-string modified "\n" t)
                                 (split-string untracked "\n" t)))))
      ;; Filter out files that were already dirty
      (cl-remove-if
       (lambda (f) (member f baseline-dirty-files))
       all-changes))))

(defun claude-code-log--generate-diff (file)
  "Generate diff for FILE.
Returns diff string, or file contents for new files."
  (if (file-exists-p file)
      (let ((git-tracked (= 0 (call-process "git" nil nil nil
                                             "ls-files" "--error-unmatch" file))))
        (if git-tracked
            (shell-command-to-string (format "git diff HEAD -- %s"
                                             (shell-quote-argument file)))
          ;; New untracked file
          (with-temp-buffer
            (insert-file-contents file)
            (format "New file: %s\n\n%s" file (buffer-string)))))
    "File deleted or moved"))

(defun claude-code-log--write-artifacts (project transaction-id artifacts)
  "Write artifact diffs to files.
PROJECT is the project name.
TRANSACTION-ID is the transaction ID.
ARTIFACTS is list of file paths."
  (let ((version-dir (claude-code-log--get-version-dir project))
        (artifact-files '()))
    (dolist (file artifacts)
      (let* ((diff (claude-code-log--generate-diff file))
             (safe-filename (replace-regexp-in-string "[/:]" "-" file))
             (artifact-file (expand-file-name
                             (format "%s-%s.diff" transaction-id safe-filename)
                             (expand-file-name "artifacts-transactional" version-dir))))
        (claude-code-log--write-to-file artifact-file diff)
        (push artifact-file artifact-files)))
    (nreverse artifact-files)))

;;;; Transaction History Functions

(defun claude-code-log--find-last-transaction (project buffer-name)
  "Find the most recent transaction ID for PROJECT in BUFFER-NAME.
Returns transaction-id or nil if none found."
  (let* ((version-dir (claude-code-log--get-version-dir project))
         (raw-dir (expand-file-name "raw-transactional" version-dir))
         (log-files (when (file-directory-p raw-dir)
                      (directory-files raw-dir t "^txn-.*\\.log$")))
         (last-txn nil)
         (last-time 0))
    ;; Find most recent transaction for this buffer
    (dolist (log-file log-files)
      (with-temp-buffer
        (insert-file-contents log-file)
        (goto-char (point-min))
        (when (re-search-forward
               (format "^;;; TRANSACTION-START: \\(txn-[^ ]+\\) .* buffer: %s$"
                       (regexp-quote buffer-name))
               nil t)
          (let* ((txn-id (match-string 1))
                 (file-time (file-attribute-modification-time
                             (file-attributes log-file))))
            (when (time-less-p last-time file-time)
              (setq last-txn txn-id
                    last-time file-time))))))
    last-txn))

(defun claude-code-log--read-transaction-metadata (project transaction-id)
  "Read metadata for TRANSACTION-ID in PROJECT.
Returns alist from JSON metadata file, or nil if not found."
  (let* ((version-dir (claude-code-log--get-version-dir project))
         (metadata-file (expand-file-name
                         (format "%s.json" transaction-id)
                         (expand-file-name "metadata" version-dir))))
    (when (file-exists-p metadata-file)
      (json-read-file metadata-file))))

(defun claude-code-log--remove-transaction-end (project transaction-id)
  "Remove TRANSACTION-END marker from TRANSACTION-ID log.
PROJECT is the project name.
TRANSACTION-ID is the transaction ID to reopen."
  (let* ((log-file (claude-code-log--get-log-file project transaction-id 'transactional))
         (backup-file (concat log-file ".backup")))
    (when (file-exists-p log-file)
      ;; Create backup
      (copy-file log-file backup-file t)
      ;; Read file and remove TRANSACTION-END
      (with-temp-buffer
        (insert-file-contents log-file)
        (goto-char (point-max))
        ;; Search backwards for TRANSACTION-END marker
        (when (re-search-backward
               (format "^;;; TRANSACTION-END: %s" (regexp-quote transaction-id))
               nil t)
          (delete-region (line-beginning-position) (point-max))
          (write-region (point-min) (point-max) log-file nil 'silent))))))

;;;; Description and Linking Functions

(defun claude-code-log--generate-default-description ()
  "Generate smart default description for transaction.
Uses first command if short, truncates if long, or falls back to artifact summary."
  (let* ((first-command claude-code-log--first-command)
         (artifacts (when claude-code-log--artifact-tracking
                      (claude-code-log--get-artifacts
                       claude-code-log--baseline-dirty-files)))
         (artifact-count (length artifacts)))
    (cond
     ;; If first command is short and descriptive, use it
     ((and first-command (< (length first-command) 60))
      first-command)

     ;; If first command is long, truncate
     ((and first-command (>= (length first-command) 60))
      (concat (substring first-command 0 57) "..."))

     ;; Fallback: artifact summary
     ((> artifact-count 0)
      (format "Modified %d file%s: %s"
              artifact-count
              (if (= artifact-count 1) "" "s")
              (string-join (mapcar #'file-name-nondirectory
                                   (seq-take artifacts 3))
                           ", ")))

     ;; Last resort: empty
     (t ""))))

(defun claude-code-log--transaction-to-consult-candidate (metadata)
  "Convert transaction METADATA to consult candidate.
Returns (display-string . transaction-id)."
  (let* ((txn-id (alist-get 'transaction_id metadata))
         (description (or (alist-get 'description metadata) ""))
         (date (or (alist-get 'start_time metadata) ""))
         (artifacts (or (alist-get 'artifacts metadata) []))
         (project (or (alist-get 'project metadata) ""))
         ;; Format: [date] description (project, N files)
         (date-str (if (> (length date) 10)
                       (substring date 0 10)
                     date))
         (display (format "%s  %s  (%s, %d files)"
                          (propertize date-str 'face 'font-lock-comment-face)
                          (if (string-empty-p description)
                              (propertize "No description" 'face 'shadow)
                            description)
                          (propertize project 'face 'font-lock-keyword-face)
                          (length artifacts))))
    (cons display txn-id)))

(defun claude-code-log--get-transaction-candidates (&optional project limit)
  "Get transaction candidates for completion.
Optional PROJECT filters to specific project (default: current).
Optional LIMIT restricts to N most recent transactions (default: all)."
  (let* ((project (or project (claude-code-log--get-project-name)))
         (version-dir (claude-code-log--get-version-dir project))
         (metadata-dir (expand-file-name "metadata" version-dir))
         (files (when (file-directory-p metadata-dir)
                  (directory-files metadata-dir t "^txn-.*\\.json$")))
         (candidates '()))
    (dolist (file files)
      (condition-case nil
          (let* ((metadata (json-read-file file))
                 (candidate (claude-code-log--transaction-to-consult-candidate metadata)))
            (push candidate candidates))
        (error nil))) ; Skip malformed JSON files
    ;; Sort by date (most recent first) and optionally limit
    (let ((sorted (sort candidates
                        (lambda (a b)
                          (string> (car a) (car b))))))
      (if limit
          (seq-take sorted limit)
        sorted))))

(defun claude-code-log--get-all-transaction-candidates (&optional limit)
  "Get transaction candidates from ALL projects.
Optional LIMIT restricts to N most recent transactions per project."
  (let ((candidates '())
        (projects-dir (expand-file-name "projects" claude-code-log-corpus-dir)))
    (when (file-directory-p projects-dir)
      (dolist (project-dir (directory-files projects-dir t "^[^.]"))
        (when (file-directory-p project-dir)
          (let ((project-name (file-name-nondirectory project-dir)))
            (setq candidates
                  (append candidates
                          (claude-code-log--get-transaction-candidates
                           project-name limit)))))))
    ;; Sort all candidates by date
    (sort candidates
          (lambda (a b)
            (string> (car a) (car b))))))

;;;; Metadata Functions

(defun claude-code-log--write-transaction-metadata (project transaction-id data)
  "Write transaction metadata JSON.
PROJECT is the project name.
TRANSACTION-ID is the transaction ID.
DATA is a plist with transaction data."
  (let* ((version-dir (claude-code-log--get-version-dir project))
         (metadata-file (expand-file-name
                         (format "%s.json" transaction-id)
                         (expand-file-name "metadata" version-dir)))
         (json-data (json-encode data)))
    (claude-code-log--write-to-file metadata-file json-data)))

(defun claude-code-log--update-standalone-metadata (project session-data)
  "Update daily standalone metadata with SESSION-DATA.
PROJECT is the project name.
SESSION-DATA is a plist with session information."
  (let* ((version-dir (claude-code-log--get-version-dir project))
         (date (claude-code-log--date))
         (metadata-file (expand-file-name
                         (format "standalone-%s.json" date)
                         (expand-file-name "metadata" version-dir)))
         (existing-data (when (file-exists-p metadata-file)
                          (json-read-file metadata-file)))
         (sessions (if existing-data
                       (append (alist-get 'sessions existing-data) (list session-data))
                     (list session-data)))
         (total-commands (if existing-data
                             (1+ (alist-get 'total_commands existing-data))
                           1))
         (total-duration (if existing-data
                             (+ (alist-get 'total_duration_seconds existing-data)
                                (plist-get session-data :duration_seconds))
                           (plist-get session-data :duration_seconds)))
         (updated-data `((date . ,date)
                         (sessions . ,sessions)
                         (total_commands . ,total-commands)
                         (total_duration_seconds . ,total-duration))))
    (claude-code-log--write-to-file metadata-file (json-encode updated-data))))

;;;; Git Clean Tree Handling

(defun claude-code-log--handle-dirty-tree ()
  "Handle dirty git tree according to configuration.
Returns t if ready to proceed, nil if cancelled."
  (let ((dirty-files (claude-code-log--get-dirty-files)))
    (pcase claude-code-log-require-clean-tree
      ('allow t) ; Always proceed

      ('error
       (error "Cannot start transaction: working tree has uncommitted changes"))

      ('auto-commit
       (message "Auto-committing changes...")
       (shell-command "git add -A")
       (shell-command (format "git commit -m \"Pre-record commit for transaction %s\""
                              (claude-code-log--generate-transaction-id)))
       t)

      ('prompt
       (let* ((file-list (mapconcat (lambda (f) (format "  %s" f))
                                    dirty-files "\n"))
              (prompt (format "Working tree has uncommitted changes:\n%s\n\nFor clean RAG data, commit these first.\n\n[c] Commit now (interactive)\n[a] Auto-commit with message\n[s] Skip this transaction\n[i] Ignore and continue anyway\n\nChoice: "
                              file-list))
              (choice (read-char-choice prompt '(?c ?a ?s ?i ?C ?A ?S ?I))))
         (message "")
         (pcase choice
           ((or ?c ?C)
            ;; Open magit or vc-dir for interactive commit
            (if (fboundp 'magit-status)
                (magit-status)
              (vc-dir default-directory))
            ;; Prompt to continue after commit
            (yes-or-no-p "Commit complete. Start transaction? "))

           ((or ?a ?A)
            ;; Auto-commit
            (shell-command "git add -A")
            (shell-command (format "git commit -m \"Pre-record commit for transaction %s\""
                                   (claude-code-log--generate-transaction-id)))
            (message "Changes committed automatically")
            t)

           ((or ?s ?S)
            ;; Skip transaction
            (message "Transaction cancelled")
            nil)

           ((or ?i ?I)
            ;; Ignore and continue
            (message "Continuing with dirty tree (artifacts may be ambiguous)")
            t)))))))

;;;; Transaction Management

;;;###autoload
(defun claude-code-record ()
  "Start a new transaction for logging Claude Code interactions.

This command begins tracking a conversation session with Claude,
capturing all commands, responses, and file changes (artifacts)
for later curation into RAG training data.

The transaction continues until you call `claude-code-commit'."
  (interactive)
  (unless (derived-mode-p 'eat-mode 'vterm-mode)
    (error "Must be called from a Claude Code buffer"))

  (when claude-code-log--transaction-id
    (message "Already in transaction: %s" claude-code-log--transaction-id)
    (cl-return-from claude-code-record))

  ;; Get project and ensure directories
  (let ((project (claude-code-log--get-project-name)))
    (claude-code-log--ensure-directories project)

    ;; Check git status
    (if (claude-code-log--in-git-repo-p)
        (progn
          (setq claude-code-log--artifact-tracking t)
          ;; Handle dirty tree if needed
          (unless (or (claude-code-log--tree-is-clean-p)
                      (claude-code-log--handle-dirty-tree))
            (cl-return-from claude-code-record)))
      ;; Not in git repo
      (message "Warning: Not in git repo. Artifact tracking disabled.")
      (setq claude-code-log--artifact-tracking nil))

    ;; Initialize transaction
    (let ((txn-id (claude-code-log--generate-transaction-id))
          (git-sha (claude-code-log--get-git-sha)))
      (setq claude-code-log--transaction-id txn-id
            claude-code-log--baseline-sha git-sha
            claude-code-log--baseline-timestamp (float-time)
            claude-code-log--baseline-buffer-point (point-max)
            claude-code-log--baseline-dirty-files (when claude-code-log--artifact-tracking
                                                    (claude-code-log--get-dirty-files))
            claude-code-log--tool-uses '()
            claude-code-log--command-count 0)

      ;; Write transaction start marker
      (claude-code-log--write-transaction-start project txn-id (buffer-name) git-sha)

      (message "Transaction started: %s" txn-id))))

;;;###autoload
(defun claude-code-commit ()
  "Commit the current transaction.

This command ends the current transaction, capturing:
- Full conversation snapshot from the buffer
- Git diffs for all changed files (artifacts)
- Metadata (duration, tool usage, file changes)

The data is written to the corpus directory for later curation."
  (interactive)
  (unless claude-code-log--transaction-id
    (error "Not in a transaction. Use `claude-code-record' first"))

  (let* ((project (claude-code-log--get-project-name))
         (txn-id claude-code-log--transaction-id)
         (start-time claude-code-log--baseline-timestamp)
         (end-time (float-time))
         (duration (round (- end-time start-time))))

    ;; TODO: Wait for Claude to finish if mid-response
    ;; For now, just capture current state

    ;; Prompt for description with smart default
    (let* ((default-desc (claude-code-log--generate-default-description))
           (prompt-text (if (string-empty-p default-desc)
                           "Transaction description: "
                         (format "Transaction description (default: %s): "
                                 (truncate-string-to-width default-desc 50))))
           (description (read-string prompt-text nil nil default-desc)))
      (setq claude-code-log--description description))

    ;; Capture conversation snapshot
    (let ((conversation (buffer-substring-no-properties
                         claude-code-log--baseline-buffer-point
                         (point-max))))
      (claude-code-log--write-conversation-snapshot project txn-id conversation))

    ;; Detect and write artifacts
    (let* ((artifacts (when claude-code-log--artifact-tracking
                        (claude-code-log--get-artifacts
                         claude-code-log--baseline-dirty-files)))
           (artifact-files (when artifacts
                             (claude-code-log--write-artifacts project txn-id artifacts)))
           (artifact-count (length artifacts)))

      ;; Write transaction end marker
      (claude-code-log--write-transaction-end project txn-id duration artifact-count)

      ;; Write metadata
      (claude-code-log--write-transaction-metadata
       project txn-id
       `((transaction_id . ,txn-id)
         (project . ,project)
         (version . "v1")
         (buffer . ,(buffer-name))
         (description . ,(or claude-code-log--description ""))
         (auto_generated_description . ,(if claude-code-log--description nil t))
         (first_command . ,(or claude-code-log--first-command ""))
         (start_time . ,(format-time-string "%Y-%m-%dT%H:%M:%S"
                                             (seconds-to-time start-time)))
         (end_time . ,(format-time-string "%Y-%m-%dT%H:%M:%S"
                                           (seconds-to-time end-time)))
         (duration_seconds . ,duration)
         (git_baseline_sha . ,claude-code-log--baseline-sha)
         (git_final_sha . ,(claude-code-log--get-git-sha))
         (commands_count . ,claude-code-log--command-count)
         (tool_uses . ,(vconcat claude-code-log--tool-uses))
         (artifacts . ,(vconcat artifacts))
         (parent_transaction . ,(or claude-code-log--parent-transaction :null))
         (relationship_type . ,(or claude-code-log--relationship-type :null))
         (related_transactions . ,(vconcat (or claude-code-log--related-transactions [])))
         (raw_log . ,(file-relative-name
                      (claude-code-log--get-log-file project txn-id 'transactional)
                      (claude-code-log--get-version-dir project)))
         (artifact_files . ,(vconcat (mapcar
                                      (lambda (f)
                                        (file-relative-name f (claude-code-log--get-version-dir project)))
                                      artifact-files)))))

      ;; Clear transaction state
      (setq claude-code-log--transaction-id nil
            claude-code-log--baseline-sha nil
            claude-code-log--baseline-timestamp nil
            claude-code-log--baseline-buffer-point nil
            claude-code-log--baseline-dirty-files nil
            claude-code-log--tool-uses nil
            claude-code-log--command-count 0
            claude-code-log--description nil
            claude-code-log--parent-transaction nil
            claude-code-log--relationship-type nil
            claude-code-log--related-transactions nil
            claude-code-log--first-command nil)

      (message "Transaction committed: %s (%d artifacts, %dm%ds)"
               txn-id artifact-count (/ duration 60) (mod duration 60)))))

;;;###autoload
(defun claude-code-reopen ()
  "Reopen the most recent transaction in this buffer.

This command allows you to continue a previously committed transaction.
It removes the TRANSACTION-END marker and restores the transaction state,
so you can add more conversation turns before committing again.

Only the most recent transaction for this buffer can be reopened.
The transaction continues with the same ID, creating a multi-session
conversation log."
  (interactive)
  (unless (derived-mode-p 'eat-mode 'vterm-mode)
    (error "Must be called from a Claude Code buffer"))

  (when claude-code-log--transaction-id
    (error "Already in a transaction: %s. Commit first before reopening"
           claude-code-log--transaction-id))

  ;; Find last transaction for this buffer
  (let* ((project (claude-code-log--get-project-name))
         (last-txn-id (claude-code-log--find-last-transaction project (buffer-name))))

    (unless last-txn-id
      (error "No previous transaction found in this buffer"))

    ;; Read existing metadata
    (let ((metadata (claude-code-log--read-transaction-metadata project last-txn-id)))
      (unless metadata
        (error "Could not read metadata for transaction %s" last-txn-id))

      ;; Remove TRANSACTION-END marker from log file
      (claude-code-log--remove-transaction-end project last-txn-id)

      ;; Restore transaction state
      (setq claude-code-log--transaction-id last-txn-id
            claude-code-log--baseline-sha (alist-get 'git_baseline_sha metadata)
            claude-code-log--baseline-timestamp (float-time) ; Reset start time to now
            claude-code-log--baseline-buffer-point (point-max)
            claude-code-log--baseline-dirty-files (when claude-code-log--artifact-tracking
                                                    (claude-code-log--get-dirty-files))
            claude-code-log--tool-uses (append (alist-get 'tool_uses metadata) nil)
            claude-code-log--command-count (alist-get 'commands_count metadata)
            claude-code-log--artifact-tracking (not (null (alist-get 'git_baseline_sha metadata))))

      ;; Write continuation marker
      (claude-code-log--write-continuation-marker project last-txn-id)

      (message "Reopened transaction: %s (continue working, commit when done)" last-txn-id))))

;;;; Event Hook Integration

(defun claude-code-log--event-listener (message)
  "Handle Claude Code events for logging.
MESSAGE is a plist with :type, :buffer-name, :json-data, :args."
  (let ((type (plist-get message :type))
        (buffer-name (plist-get message :buffer-name))
        (json-data (plist-get message :json-data)))

    (when-let ((buffer (get-buffer buffer-name)))
      (with-current-buffer buffer
        (cond
         ;; Transactional mode: record events for metadata
         (claude-code-log--transaction-id
          (when (memq type '(pre-tool-use post-tool-use))
            (let* ((parsed (when json-data
                             (condition-case nil
                                 (json-read-from-string json-data)
                               (error nil))))
                   (tool-name (when parsed (alist-get 'tool_name parsed)))
                   (tool-input (when parsed (alist-get 'tool_input parsed))))
              (when tool-name
                (push `((type . ,type)
                        (tool . ,tool-name)
                        (timestamp . ,(claude-code-log--timestamp)))
                      claude-code-log--tool-uses)
                ;; Write tool use marker
                (let ((project (claude-code-log--get-project-name)))
                  (claude-code-log--write-tool-use
                   project
                   claude-code-log--transaction-id
                   tool-name
                   (if tool-input
                       (format "%s" tool-input)
                     "")))))))

         ;; Standalone mode: minimal logging
         ((and (not claude-code-log--transaction-id)
               claude-code-log
               claude-code-log--enabled-internal)
          ;; TODO: Implement standalone logging
          nil))))))

;;;; Command Interception

(defun claude-code-log--wrap-send-command (orig-fun cmd)
  "Advice wrapper around `claude-code--do-send-command'.
ORIG-FUN is the original function.
CMD is the command string."
  (when (and claude-code-log--enabled-internal
             (or claude-code-log--transaction-id
                 claude-code-log))
    (let* ((project (claude-code-log--get-project-name))
           (txn-id claude-code-log--transaction-id)
           (log-type (if txn-id 'transactional 'standalone)))

      ;; Ensure directories exist
      (claude-code-log--ensure-directories project)

      ;; Log command
      (claude-code-log--write-command project txn-id log-type cmd)

      ;; Increment command counter for transactions
      (when txn-id
        (setq claude-code-log--command-count
              (1+ claude-code-log--command-count))
        ;; Capture first command for description generation
        (unless claude-code-log--first-command
          (setq claude-code-log--first-command cmd)))))

  ;; Call original function
  (funcall orig-fun cmd))

;;;; Transaction Linking Commands

;;;###autoload
(defun claude-code-record-with-parent ()
  "Start a new transaction with a parent link.

Prompts for a parent transaction from the current project and
establishes a relationship (parent-child, follows, or related).
This creates a linked conversation history useful for tracking
feature evolution and related work."
  (interactive)
  (let* ((candidates (claude-code-log--get-transaction-candidates nil 20))
         (selected (if candidates
                       (completing-read "Parent transaction: "
                                       candidates
                                       nil nil nil
                                       'claude-code-log--parent-history)
                     (error "No transactions found in current project")))
         (parent-id (cdr (assoc selected candidates)))
         (relationship (completing-read "Relationship: "
                                       '("parent-child" "follows" "related")
                                       nil t nil nil "parent-child")))

    ;; Start transaction
    (claude-code-record)

    ;; Store parent info
    (setq-local claude-code-log--parent-transaction parent-id
                claude-code-log--relationship-type relationship)

    (message "Transaction started with parent: %s (%s)" parent-id relationship)))

;;;###autoload
(defun claude-code-link-to-parent ()
  "Link current transaction to a parent.

Must be called while in an active transaction. Allows you to
establish a parent relationship after starting the transaction."
  (interactive)
  (unless claude-code-log--transaction-id
    (error "Not in a transaction. Use `claude-code-record' first"))

  (when claude-code-log--parent-transaction
    (unless (yes-or-no-p
             (format "Already linked to parent %s. Replace? "
                     claude-code-log--parent-transaction))
      (user-error "Cancelled")))

  (let* ((candidates (claude-code-log--get-transaction-candidates nil 20))
         (selected (completing-read "Parent transaction: "
                                   candidates
                                   nil nil nil
                                   'claude-code-log--parent-history))
         (parent-id (cdr (assoc selected candidates)))
         (relationship (completing-read "Relationship: "
                                       '("parent-child" "follows" "related")
                                       nil t nil nil "parent-child")))

    (setq-local claude-code-log--parent-transaction parent-id
                claude-code-log--relationship-type relationship)

    (message "Linked to parent: %s (%s)" parent-id relationship)))

;;;###autoload
(defun claude-code-add-related ()
  "Add a related transaction to the current transaction.

Must be called while in an active transaction. Allows you to
link multiple related transactions (many-to-many relationship)."
  (interactive)
  (unless claude-code-log--transaction-id
    (error "Not in a transaction. Use `claude-code-record' first"))

  (let* ((candidates (claude-code-log--get-transaction-candidates nil 20))
         (selected (completing-read "Related transaction: "
                                   candidates
                                   nil nil nil
                                   'claude-code-log--parent-history))
         (related-id (cdr (assoc selected candidates))))

    ;; Add to list if not already present
    (unless (member related-id claude-code-log--related-transactions)
      (push related-id claude-code-log--related-transactions)
      (message "Added related transaction: %s" related-id))))

;;;###autoload
(defun claude-code-log-search-transactions ()
  "Search all transactions by description, command, or project.

Uses consult/vertico for rich filtering. Search across all projects
and navigate transaction history."
  (interactive)
  (let* ((all-candidates (claude-code-log--get-all-transaction-candidates))
         (selected (if all-candidates
                       (completing-read "Search transactions: " all-candidates)
                     (error "No transactions found")))
         (txn-id (cdr (assoc selected all-candidates)))
         (project (claude-code-log--get-project-from-txn-id txn-id))
         (log-file (claude-code-log--get-log-file project txn-id 'transactional)))

    ;; Open transaction log in view mode
    (if (file-exists-p log-file)
        (progn
          (find-file-read-only log-file)
          (message "Viewing transaction: %s" txn-id))
      (message "Log file not found: %s" log-file))))

(defun claude-code-log--get-project-from-txn-id (txn-id)
  "Get project name from TXN-ID by searching metadata files."
  (let ((projects-dir (expand-file-name "projects" claude-code-log-corpus-dir))
        (found-project nil))
    (when (file-directory-p projects-dir)
      (dolist (project-dir (directory-files projects-dir t "^[^.]"))
        (when (and (file-directory-p project-dir) (not found-project))
          (let* ((project-name (file-name-nondirectory project-dir))
                 (version-dir (claude-code-log--get-version-dir project-name))
                 (metadata-file (expand-file-name
                                 (format "%s.json" txn-id)
                                 (expand-file-name "metadata" version-dir))))
            (when (file-exists-p metadata-file)
              (setq found-project project-name))))))
    (or found-project "unclassified")))

;;;; Installation

;;;###autoload
(defun claude-code-log-enable ()
  "Enable Claude Code logging system."
  (interactive)
  (advice-add 'claude-code--do-send-command
              :around #'claude-code-log--wrap-send-command)
  (add-hook 'claude-code-event-hook #'claude-code-log--event-listener)
  (message "Claude Code logging enabled"))

;;;###autoload
(defun claude-code-log-disable ()
  "Disable Claude Code logging system."
  (interactive)
  (advice-remove 'claude-code--do-send-command
                 #'claude-code-log--wrap-send-command)
  (remove-hook 'claude-code-event-hook #'claude-code-log--event-listener)
  (message "Claude Code logging disabled"))

(provide 'claude-code-log)

;;; claude-code-log.el ends here
