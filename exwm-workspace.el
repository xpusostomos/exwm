;;; exwm-workspace.el --- Workspace Module for EXWM  -*- lexical-binding: t -*-

;; Copyright (C) 2015-2016 Free Software Foundation, Inc.

;; Author: Chris Feng <chris.w.feng@gmail.com>

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This module adds workspace support for EXWM.

;;; Code:

(require 'exwm-core)

(defvar exwm-workspace-number 4 "Number of workspaces (1 ~ 10).")
(defvar exwm-workspace--list nil "List of all workspaces (Emacs frames).")
(defvar exwm-workspace--switch-map
  (let ((map (make-sparse-keymap)))
    (define-key map [t] (lambda () (interactive)))
    (dotimes (i 10)
      (define-key map (int-to-string i)
        `(lambda ()
           (interactive)
           (when (< ,i exwm-workspace-number)
             (goto-history-element ,(1+ i))
             (exit-minibuffer)))))
    (define-key map "\C-a" (lambda () (interactive) (goto-history-element 1)))
    (define-key map "\C-e" (lambda ()
                             (interactive)
                             (goto-history-element exwm-workspace-number)))
    (define-key map "\C-g" #'abort-recursive-edit)
    (define-key map "\C-]" #'abort-recursive-edit)
    (define-key map "\C-j" #'exit-minibuffer)
    ;; (define-key map "\C-m" #'exit-minibuffer) ;not working
    (define-key map [return] #'exit-minibuffer)
    (define-key map " " #'exit-minibuffer)
    (define-key map "\C-f" #'previous-history-element)
    (define-key map "\C-b" #'next-history-element)
    ;; Alternative keys
    (define-key map [right] #'previous-history-element)
    (define-key map [left] #'next-history-element)
    map)
  "Keymap used for interactively switch workspace.")

(defvar exwm-workspace--switch-history nil
  "History for `read-from-minibuffer' to interactively switch workspace.")
(defvar exwm-workspace--switch-history-outdated nil
  "Non-nil to indicate `exwm-workspace--switch-history' is outdated.")

(defun exwm-workspace--update-switch-history ()
  "Update the history for switching workspace to reflect the latest status."
  (when exwm-workspace--switch-history-outdated
    (setq exwm-workspace--switch-history-outdated nil)
    (let ((sequence (number-sequence 0 (1- exwm-workspace-number)))
          (not-empty (make-vector exwm-workspace-number nil)))
      (dolist (i exwm--id-buffer-alist)
        (with-current-buffer (cdr i)
          (when exwm--frame
            (setf (aref not-empty
                        (cl-position exwm--frame exwm-workspace--list))
                  t))))
      (setq exwm-workspace--switch-history
            (mapcar
             (lambda (i)
               (mapconcat
                (lambda (j)
                  (format (if (= i j) "[%s]" " %s ")
                          (propertize
                           (int-to-string j)
                           'face
                           (cond ((frame-parameter (elt exwm-workspace--list j)
                                                   'exwm--urgency)
                                  '(:foreground "orange"))
                                 ((aref not-empty j) '(:foreground "green"))
                                 (t nil)))))
                sequence ""))
             sequence)))))

(defvar exwm-workspace--current nil "Current active workspace.")
(defvar exwm-workspace-current-index 0 "Index of current active workspace.")
(defvar exwm-workspace-show-all-buffers nil
  "Non-nil to show buffers on other workspaces.")
(defvar exwm-workspace--minibuffer nil
  "The minibuffer frame shared among all frames.")
(defvar exwm-workspace-minibuffer-position nil
  "Position of the minibuffer frame.

Value nil means to use the default position which is fixed at bottom, while
'top and 'bottom mean to use an auto-hiding minibuffer.")
(defvar exwm-workspace-display-echo-area-timeout 1
  "Timeout for displaying echo area.")
(defvar exwm-workspace--display-echo-area-timer nil
  "Timer for auto-hiding echo area.")

;;;###autoload
(defun exwm-workspace--get-geometry (frame)
  "Return the geometry of frame FRAME."
  (or (frame-parameter frame 'exwm-geometry)
      (make-instance 'xcb:RECTANGLE
                     :x 0
                     :y 0
                     :width (x-display-pixel-width)
                     :height (x-display-pixel-height))))

;;;###autoload
(defun exwm-workspace--current-width ()
  "Return the width of current workspace."
  (let ((geometry (frame-parameter exwm-workspace--current 'exwm-geometry)))
    (if geometry
        (slot-value geometry 'width)
      (x-display-pixel-width))))

;;;###autoload
(defun exwm-workspace--current-height ()
  "Return the height of current workspace."
  (let ((geometry (frame-parameter exwm-workspace--current 'exwm-geometry)))
    (if geometry
        (slot-value geometry 'height)
      (x-display-pixel-height))))

;;;###autoload
(defun exwm-workspace--minibuffer-own-frame-p ()
  "Reports whether the minibuffer is displayed in its own frame."
  (memq exwm-workspace-minibuffer-position '(top bottom)))

(defvar exwm-workspace--id-struts-alist nil "Alist of X window and struts.")
(defvar exwm-workspace--struts nil "Areas occupied by struts.")

(defun exwm-workspace--update-struts ()
  "Update `exwm-workspace--struts'."
  (setq exwm-workspace--struts nil)
  (let (struts struts*)
    (dolist (pair exwm-workspace--id-struts-alist)
      (setq struts (cdr pair))
      (dotimes (i 4)
        (when (/= 0 (aref struts i))
          (setq struts*
                (vector (aref [left right top bottom] i)
                        (aref struts i)
                        (when (= 12 (length struts))
                          (substring struts (+ 4 (* i 2)) (+ 6 (* i 2))))))
          (if (= 0 (mod i 2))
              ;; Make left/top processed first.
              (push struts* exwm-workspace--struts)
            (setq exwm-workspace--struts
                  (append exwm-workspace--struts (list struts*)))))))))

(defvar exwm-workspace--workareas nil "Workareas (struts excluded).")

(defun exwm-workspace--update-workareas ()
  "Update `exwm-workspace--workareas' and set _NET_WORKAREA."
  (let ((root-width (x-display-pixel-width))
        (root-height (x-display-pixel-height))
        workareas
        edge width position
        delta)
    ;; Calculate workareas with no struts.
    (if (frame-parameter (car exwm-workspace--list) 'exwm-geometry)
        ;; Use the 'exwm-geometry' frame parameter if possible.
        (dolist (f exwm-workspace--list)
          (with-slots (x y width height) (frame-parameter f 'exwm-geometry)
            (setq workareas (append workareas
                                    (list (vector x y width height))))))
      ;; Fall back to use the screen size.
      (let ((workarea (vector 0 0 root-width root-height)))
        (dotimes (_ exwm-workspace-number)
          (push workarea workareas))))
    ;; Exclude areas occupied by struts.
    (dolist (struts exwm-workspace--struts)
      (setq edge (aref struts 0)
            width (aref struts 1)
            position (aref struts 2))
      (dolist (w workareas)
        (pcase edge
          ;; Left and top are always processed first.
          (`left
           (setq delta (- (aref w 0) width))
           (when (and (< delta 0)
                      (< (max (aref position 0) (aref w 1))
                         (min (aref position 1)
                              (+ (aref w 1) (aref w 3)))))
             (cl-incf (aref w 2) delta)
             (setf (aref w 0) width)))
          (`right
           (setq delta (- root-width (aref w 0) (aref w 2) width))
           (when (and (< delta 0)
                      (< (max (aref position 0) (aref w 1))
                         (min (aref position 1)
                              (+ (aref w 1) (aref w 3)))))
             (cl-incf (aref w 2) delta)))
          (`top
           (setq delta (- (aref w 1) width))
           (when (and (< delta 0)
                      (< (max (aref position 0) (aref w 0))
                         (min (aref position 1)
                              (+ (aref w 0) (aref w 2)))))
             (cl-incf (aref w 3) delta)
             (setf (aref w 1) width)))
          (`bottom
           (setq delta (- root-height (aref w 1) (aref w 3) width))
           (when (and (< delta 0)
                      (< (max (aref position 0) (aref w 0))
                         (min (aref position 1)
                              (+ (aref w 0) (aref w 2)))))
             (cl-incf (aref w 3) delta))))))
    ;; Save the result.
    (setq exwm-workspace--workareas workareas)
    ;; Update _NET_WORKAREA.
    (xcb:+request exwm--connection
        (make-instance 'xcb:ewmh:set-_NET_WORKAREA
                       :window exwm--root
                       :data (mapconcat #'vconcat workareas [])))
    (xcb:flush exwm--connection)))

(defvar exwm-workspace--fullscreen-frame-count 0
  "Count the fullscreen workspace frames.")

(declare-function exwm-layout--resize-container "exwm-layout.el"
                  (id container x y width height &optional container-only))

(defun exwm-workspace--set-fullscreen (frame)
  "Make frame FRAME fullscreen according to `exwm-workspace--workareas'."
  (let ((workarea (elt exwm-workspace--workareas
                       (cl-position frame exwm-workspace--list)))
        (id (frame-parameter frame 'exwm-outer-id))
        (container (frame-parameter frame 'exwm-container))
        (workspace (frame-parameter frame 'exwm-workspace))
        x y width height)
    (setq x (aref workarea 0)
          y (aref workarea 1)
          width (aref workarea 2)
          height (aref workarea 3))
    (when (and (eq frame exwm-workspace--current)
               (exwm-workspace--minibuffer-own-frame-p))
      (exwm-workspace--resize-minibuffer-frame))
    (exwm-layout--resize-container id container 0 0 width height)
    (exwm-layout--resize-container nil workspace x y width height t)
    (xcb:flush exwm--connection))
  ;; This is only used for workspace initialization.
  (when exwm-workspace--fullscreen-frame-count
    (cl-incf exwm-workspace--fullscreen-frame-count)))

(defun exwm-workspace--resize-minibuffer-frame ()
  "Resize minibuffer (and its container) to fit the size of workspace."
  (cl-assert (exwm-workspace--minibuffer-own-frame-p))
  (let ((workarea (elt exwm-workspace--workareas exwm-workspace-current-index))
        (container (frame-parameter exwm-workspace--minibuffer
                                    'exwm-container))
        y width)
    (setq y (if (eq exwm-workspace-minibuffer-position 'top)
                0
              (- (aref workarea 3)
                 (frame-pixel-height exwm-workspace--minibuffer)))
          width (aref workarea 2))
    (xcb:+request exwm--connection
        (make-instance 'xcb:ConfigureWindow
                       :window container
                       :value-mask (logior xcb:ConfigWindow:Y
                                           xcb:ConfigWindow:Width
                                           xcb:ConfigWindow:StackMode)
                       :y y
                       :width width
                       :stack-mode xcb:StackMode:Above))
    (set-frame-width exwm-workspace--minibuffer width nil t)))

(defvar exwm-workspace-switch-hook nil
  "Normal hook run after switching workspace.")

;;;###autoload
(defun exwm-workspace-switch (index &optional force)
  "Switch to workspace INDEX. Query for INDEX if it's not specified.

The optional FORCE option is for internal use only."
  (interactive
   (list
    (unless (and (eq major-mode 'exwm-mode) exwm--fullscreen) ;it's invisible
      (exwm-workspace--update-switch-history)
      (let* ((history-add-new-input nil) ;prevent modifying history
             (idx (read-from-minibuffer
                   "Workspace: " (elt exwm-workspace--switch-history
                                      exwm-workspace-current-index)
                   exwm-workspace--switch-map nil
                   `(exwm-workspace--switch-history
                     . ,(1+ exwm-workspace-current-index)))))
        (cl-position idx exwm-workspace--switch-history :test #'equal)))))
  (when index
    (unless (and (<= 0 index) (< index exwm-workspace-number))
      (user-error "[EXWM] Workspace index out of range: %d" index))
    (when (or force (/= exwm-workspace-current-index index))
      (let* ((frame (elt exwm-workspace--list index))
             (workspace (frame-parameter frame 'exwm-workspace))
             (window (frame-parameter frame 'exwm-selected-window)))
        (unless (window-live-p window)
          (setq window (frame-selected-window frame)))
        ;; Raise the workspace container.
        (xcb:+request exwm--connection
            (make-instance 'xcb:ConfigureWindow
                           :window workspace
                           :value-mask xcb:ConfigWindow:StackMode
                           :stack-mode xcb:StackMode:Above))
        ;; Raise X windows with struts set if there's no fullscreen X window.
        (unless (buffer-local-value 'exwm--fullscreen (window-buffer window))
          (dolist (pair exwm-workspace--id-struts-alist)
            (xcb:+request exwm--connection
                (make-instance 'xcb:ConfigureWindow
                               :window (car pair)
                               :value-mask xcb:ConfigWindow:StackMode
                               :stack-mode xcb:StackMode:Above))))
        (setq exwm-workspace--current frame
              exwm-workspace-current-index index)
        (unless (memq (selected-frame) exwm-workspace--list)
          ;; Save the floating frame window selected on the previous workspace.
          (set-frame-parameter (with-current-buffer (window-buffer)
                                 exwm--frame)
                               'exwm-selected-window (selected-window)))
        (select-window window)
        (set-frame-parameter frame 'exwm-selected-window nil)
        ;; Close the (possible) active minibuffer
        (when (active-minibuffer-window)
          (run-with-idle-timer 0 nil (lambda () (abort-recursive-edit))))
        (if (not (exwm-workspace--minibuffer-own-frame-p))
            (setq default-minibuffer-frame frame)
          ;; Resize/reposition the minibuffer frame
          (xcb:+request exwm--connection
              (make-instance 'xcb:ReparentWindow
                             :window
                             (frame-parameter exwm-workspace--minibuffer
                                              'exwm-container)
                             :parent (frame-parameter frame 'exwm-workspace)
                             :x 0 :y 0))
          (exwm-workspace--resize-minibuffer-frame))
        ;; Hide windows in other workspaces by preprending a space
        (unless exwm-workspace-show-all-buffers
          (dolist (i exwm--id-buffer-alist)
            (with-current-buffer (cdr i)
              (let ((name (replace-regexp-in-string "^\\s-*" ""
                                                    (buffer-name))))
                (exwm-workspace-rename-buffer (if (eq frame exwm--frame)
                                                  name
                                                (concat " " name)))))))
        ;; Update demands attention flag
        (set-frame-parameter frame 'exwm--urgency nil)
        ;; Update switch workspace history
        (setq exwm-workspace--switch-history-outdated t)
        ;; Set _NET_CURRENT_DESKTOP.
        (xcb:+request exwm--connection
            (make-instance 'xcb:ewmh:set-_NET_CURRENT_DESKTOP
                           :window exwm--root :data index))
        (xcb:flush exwm--connection))
      (run-hooks 'exwm-workspace-switch-hook))))

(defun exwm-workspace--on-focus-in ()
  "Handle unexpected frame switch."
  ;; `focus-in-hook' is run by `handle-switch-frame'.
  (unless (eq this-command #'handle-switch-frame)
    (let ((index (cl-position (selected-frame) exwm-workspace--list)))
      (exwm--log "Focus on workspace %s" index)
      (when (and index (/= index exwm-workspace-current-index))
        (exwm--log "Workspace was switched unexpectedly")
        (exwm-workspace-switch index)))))

(defun exwm-workspace--set-desktop (id)
  "Set _NET_WM_DESKTOP for X window ID."
  (with-current-buffer (exwm--id->buffer id)
    (xcb:+request exwm--connection
        (make-instance 'xcb:ewmh:set-_NET_WM_DESKTOP
                       :window id
                       :data (cl-position exwm--frame exwm-workspace--list)))))

(defvar exwm-floating-border-width)
(defvar exwm-floating-border-color)

(declare-function exwm-layout--show "exwm-layout.el" (id &optional window))
(declare-function exwm-layout--hide "exwm-layout.el" (id))
(declare-function exwm-layout--refresh "exwm-layout.el")
(declare-function exwm-layout--other-buffer-predicate "exwm-layout.el" (buffer))

;;;###autoload
(defun exwm-workspace-move-window (index &optional id)
  "Move window ID to workspace INDEX."
  (interactive
   (list
    (progn
      (exwm-workspace--update-switch-history)
      (let* ((history-add-new-input nil)  ;prevent modifying history
             (idx (read-from-minibuffer
                   "Workspace: " (elt exwm-workspace--switch-history
                                      exwm-workspace-current-index)
                   exwm-workspace--switch-map nil
                   `(exwm-workspace--switch-history
                     . ,(1+ exwm-workspace-current-index)))))
        (cl-position idx exwm-workspace--switch-history :test #'equal)))))
  (unless id (setq id (exwm--buffer->id (window-buffer))))
  (unless (and (<= 0 index) (< index exwm-workspace-number))
    (user-error "[EXWM] Workspace index out of range: %d" index))
  (with-current-buffer (exwm--id->buffer id)
    (let ((frame (elt exwm-workspace--list index)))
      (unless (eq exwm--frame frame)
        (unless exwm-workspace-show-all-buffers
          (let ((name (replace-regexp-in-string "^\\s-*" "" (buffer-name))))
            (exwm-workspace-rename-buffer
             (if (= index exwm-workspace-current-index)
                 name
               (concat " " name)))))
        (setq exwm--frame frame)
        (if exwm--floating-frame
            ;; Move the floating container.
            (with-slots (x y)
                (xcb:+request-unchecked+reply exwm--connection
                    (make-instance 'xcb:GetGeometry :drawable exwm--container))
              (xcb:+request exwm--connection
                  (make-instance 'xcb:ReparentWindow
                                 :window exwm--container
                                 :parent
                                 (frame-parameter frame 'exwm-workspace)
                                 :x x :y y))
              (xcb:flush exwm--connection)
              (if (exwm-workspace--minibuffer-own-frame-p)
                  (when (= index exwm-workspace-current-index)
                    (select-frame-set-input-focus exwm--floating-frame)
                    (exwm-layout--refresh))
                ;; The frame needs to be recreated since it won't use the
                ;; minibuffer on the new workspace.
                (let* ((old-frame exwm--floating-frame)
                       (new-frame
                        (with-current-buffer
                            (or (get-buffer "*scratch*")
                                (progn
                                  (set-buffer-major-mode
                                   (get-buffer-create "*scratch*"))
                                  (get-buffer "*scratch*")))
                          (make-frame
                           `((minibuffer . ,(minibuffer-window frame))
                             (background-color . ,exwm-floating-border-color)
                             (internal-border-width
                              . ,exwm-floating-border-width)
                             (left . 10000)
                             (top . 10000)
                             (width . ,window-min-width)
                             (height . ,window-min-height)
                             (unsplittable . t)))))
                       (outer-id (string-to-number
                                  (frame-parameter new-frame
                                                   'outer-window-id)))
                       (frame-container (frame-parameter old-frame
                                                         'exwm-container))
                       (window (frame-root-window new-frame)))
                  (set-frame-parameter new-frame 'exwm-outer-id outer-id)
                  (set-frame-parameter new-frame 'exwm-container
                                       frame-container)
                  (make-frame-invisible new-frame)
                  (set-frame-size new-frame
                                  (frame-pixel-width old-frame)
                                  (frame-pixel-height old-frame)
                                  t)
                  (xcb:+request exwm--connection
                      (make-instance 'xcb:ReparentWindow
                                     :window outer-id
                                     :parent frame-container
                                     :x 0 :y 0))
                  (xcb:flush exwm--connection)
                  (with-current-buffer (exwm--id->buffer id)
                    (setq window-size-fixed nil
                          exwm--frame frame
                          exwm--floating-frame new-frame)
                    (set-window-dedicated-p (frame-root-window old-frame) nil)
                    (remove-hook 'window-configuration-change-hook
                                 #'exwm-layout--refresh)
                    (set-window-buffer window (current-buffer))
                    (add-hook 'window-configuration-change-hook
                              #'exwm-layout--refresh)
                    (delete-frame old-frame)
                    (set-window-dedicated-p window t)
                    (exwm-layout--show id window))
                  (if (/= index exwm-workspace-current-index)
                      (make-frame-visible new-frame)
                    (select-frame-set-input-focus new-frame)
                    (redisplay))))
              ;; Update the 'exwm-selected-window' frame parameter.
              (when (/= index exwm-workspace-current-index)
                (with-current-buffer (exwm--id->buffer id)
                  (set-frame-parameter frame 'exwm-selected-window
                                       (frame-root-window
                                        exwm--floating-frame)))))
          ;; Move the X window container.
          (if (= index exwm-workspace-current-index)
              (set-window-buffer (get-buffer-window (current-buffer) t)
                                 (other-buffer))
            (bury-buffer)
            ;; Clear the 'exwm-selected-window' frame parameter.
            (set-frame-parameter frame 'exwm-selected-window nil))
          (exwm-layout--hide id)
          ;; (current-buffer) is changed.
          (with-current-buffer (exwm--id->buffer id)
            ;; Reparent to the destination workspace.
            (xcb:+request exwm--connection
                (make-instance 'xcb:ReparentWindow
                               :window exwm--container
                               :parent (frame-parameter frame 'exwm-workspace)
                               :x 0 :y 0))
            ;; Place it just above the destination frame container.
            (xcb:+request exwm--connection
                (make-instance 'xcb:ConfigureWindow
                               :window exwm--container
                               :value-mask (logior xcb:ConfigWindow:Sibling
                                                   xcb:ConfigWindow:StackMode)
                               :sibling (frame-parameter frame 'exwm-container)
                               :stack-mode xcb:StackMode:Above)))
          (xcb:flush exwm--connection)
          (set-window-buffer (frame-selected-window frame)
                             (exwm--id->buffer id)))
        ;; Set _NET_WM_DESKTOP.
        (exwm-workspace--set-desktop id)
        (xcb:flush exwm--connection)))
    (setq exwm-workspace--switch-history-outdated t)))

;;;###autoload
(defun exwm-workspace-switch-to-buffer (buffer-or-name)
  "Make the current Emacs window display another buffer."
  (interactive
   (let ((inhibit-quit t))
     ;; Show all buffers
     (unless exwm-workspace-show-all-buffers
       (dolist (pair exwm--id-buffer-alist)
         (with-current-buffer (cdr pair)
           (when (= ?\s (aref (buffer-name) 0))
             (rename-buffer (substring (buffer-name) 1))))))
     (prog1
         (with-local-quit
           (list (get-buffer (read-buffer "Switch to buffer: " nil t))))
       ;; Hide buffers on other workspaces
       (unless exwm-workspace-show-all-buffers
         (dolist (pair exwm--id-buffer-alist)
           (with-current-buffer (cdr pair)
             (unless (or (eq exwm--frame exwm-workspace--current)
                         (= ?\s (aref (buffer-name) 0)))
               (rename-buffer (concat " " (buffer-name))))))))))
  (when buffer-or-name
    (with-current-buffer buffer-or-name
      (if (eq major-mode 'exwm-mode)
          ;; EXWM buffer.
          (if (eq exwm--frame exwm-workspace--current)
              ;; On the current workspace.
              (if (not exwm--floating-frame)
                  (switch-to-buffer buffer-or-name)
                ;; Select the floating frame.
                (select-frame-set-input-focus exwm--floating-frame)
                (select-window (frame-root-window exwm--floating-frame)))
            ;; On another workspace.
            (exwm-workspace-move-window exwm-workspace-current-index
                                        exwm--id))
        ;; Ordinary buffer.
        (switch-to-buffer buffer-or-name)))))

(defun exwm-workspace-rename-buffer (newname)
  "Rename a buffer."
  (let ((hidden (= ?\s (aref newname 0)))
        (basename (replace-regexp-in-string "<[0-9]+>$" "" newname))
        (counter 1)
        tmp)
    (when hidden (setq basename (substring basename 1)))
    (setq newname basename)
    (while (and (setq tmp (or (get-buffer newname)
                              (get-buffer (concat " " newname))))
                (not (eq tmp (current-buffer))))
      (setq newname (format "%s<%d>" basename (cl-incf counter))))
    (rename-buffer (concat (and hidden " ") newname))))

(defun exwm-workspace--x-create-frame (orig-fun params)
  "Set override-redirect on the frame created by `x-create-frame'."
  (let ((frame (funcall orig-fun params)))
    (xcb:+request exwm--connection
        (make-instance 'xcb:ChangeWindowAttributes
                       :window (string-to-number
                                (frame-parameter frame 'outer-window-id))
                       :value-mask xcb:CW:OverrideRedirect
                       :override-redirect 1))
    (xcb:flush exwm--connection)
    frame))

(defun exwm-workspace--update-minibuffer (&optional echo-area)
  "Update the minibuffer frame."
  (let ((height
         (with-current-buffer
             (window-buffer (minibuffer-window exwm-workspace--minibuffer))
           (max 1
                (if echo-area
                    (let ((width (frame-width exwm-workspace--minibuffer))
                          (result 0))
                      (mapc (lambda (i)
                              (setq result
                                    (+ result
                                       (ceiling (1+ (length i)) width))))
                            (split-string (or (current-message) "") "\n"))
                      result)
                  (count-screen-lines))))))
    (when (and (integerp max-mini-window-height)
               (> height max-mini-window-height))
      (setq height max-mini-window-height))
    (set-frame-height exwm-workspace--minibuffer height)))

(defun exwm-workspace--on-ConfigureNotify (data _synthetic)
  "Adjust the container to fit the minibuffer frame."
  (let ((obj (make-instance 'xcb:ConfigureNotify))
        value-mask y)
    (xcb:unmarshal obj data)
    (with-slots (window height) obj
      (when (eq (frame-parameter exwm-workspace--minibuffer 'exwm-outer-id)
                window)
        (when (and (floatp max-mini-window-height)
                   (> height (* max-mini-window-height
                                (exwm-workspace--current-height))))
          (setq height (floor
                        (* max-mini-window-height
                           (exwm-workspace--current-height))))
          (xcb:+request exwm--connection
              (make-instance 'xcb:ConfigureWindow
                             :window window
                             :value-mask xcb:ConfigWindow:Height
                             :height height)))
        (if (eq exwm-workspace-minibuffer-position 'top)
            (setq value-mask xcb:ConfigWindow:Height
                  y 0)
          (setq value-mask (logior xcb:ConfigWindow:Y xcb:ConfigWindow:Height)
                y (- (aref (elt exwm-workspace--workareas
                                exwm-workspace-current-index)
                           3)
                     height)))
        (xcb:+request exwm--connection
            (make-instance 'xcb:ConfigureWindow
                           :window (frame-parameter exwm-workspace--minibuffer
                                                    'exwm-container)
                           :value-mask value-mask
                           :y y
                           :height height))
        (xcb:flush exwm--connection)))))

(defun exwm-workspace--display-buffer (buffer alist)
  "Display BUFFER as if the current workspace is selected."
  ;; Only when the floating minibuffer frame is selected.
  ;; This also protect this functions from being recursively called.
  (when (eq (selected-frame) exwm-workspace--minibuffer)
    (with-selected-frame exwm-workspace--current
      (display-buffer buffer alist))))

(defun exwm-workspace--show-minibuffer ()
  "Show the minibuffer frame."
  ;; Cancel pending timer.
  (when exwm-workspace--display-echo-area-timer
    (cancel-timer exwm-workspace--display-echo-area-timer)
    (setq exwm-workspace--display-echo-area-timer nil))
  ;; Show the minibuffer frame.
  (xcb:+request exwm--connection
      (make-instance 'xcb:MapWindow
                     :window (frame-parameter exwm-workspace--minibuffer
                                              'exwm-container)))
  (xcb:flush exwm--connection)
  ;; Unfortunately we need the following lines to workaround a cursor
  ;; flickering issue for line-mode floating X windows.  They just make the
  ;; minibuffer appear to be focused.
  (with-current-buffer (window-buffer (minibuffer-window
                                       exwm-workspace--minibuffer))
    (setq cursor-in-non-selected-windows
          (frame-parameter exwm-workspace--minibuffer 'cursor-type))))


(defun exwm-workspace--hide-minibuffer ()
  "Hide the minibuffer frame."
  ;; Hide the minibuffer frame.
  (xcb:+request exwm--connection
      (make-instance 'xcb:UnmapWindow
                     :window (frame-parameter exwm-workspace--minibuffer
                                              'exwm-container)))
  (xcb:flush exwm--connection))

(defun exwm-workspace--on-minibuffer-setup ()
  "Run in minibuffer-setup-hook to show the minibuffer and its container."
  (when (and (= 1 (minibuffer-depth))
             ;; Exclude non-graphical frames.
             (frame-parameter nil 'exwm-outer-id))
    (add-hook 'post-command-hook #'exwm-workspace--update-minibuffer)
    (exwm-workspace--show-minibuffer)
    ;; Set input focus on the Emacs frame
    (x-focus-frame (window-frame (minibuffer-selected-window)))))

(defun exwm-workspace--on-minibuffer-exit ()
  "Run in minibuffer-exit-hook to hide the minibuffer container."
  (when (and (= 1 (minibuffer-depth))
             ;; Exclude non-graphical frames.
             (frame-parameter nil 'exwm-outer-id))
    (remove-hook 'post-command-hook #'exwm-workspace--update-minibuffer)
    (exwm-workspace--hide-minibuffer)))

(defvar exwm-input--during-command)

(defun exwm-workspace--on-echo-area-dirty ()
  "Run when new message arrives to show the echo area and its container."
  (when (and (not (active-minibuffer-window))
             ;; Exclude non-graphical frames.
             (frame-parameter nil 'exwm-outer-id)
             (or (current-message)
                 cursor-in-echo-area))
    (exwm-workspace--update-minibuffer t)
    (exwm-workspace--show-minibuffer)
    (unless (or (not exwm-workspace-display-echo-area-timeout)
                exwm-input--during-command ;e.g. read-event
                input-method-use-echo-area)
      (setq exwm-workspace--display-echo-area-timer
            (run-with-timer exwm-workspace-display-echo-area-timeout nil
                            #'exwm-workspace--on-echo-area-clear)))))

(defun exwm-workspace--on-echo-area-clear ()
  "Run in echo-area-clear-hook to hide echo area container."
  (when (frame-parameter nil 'exwm-outer-id) ;Exclude non-graphical frames.
    (unless (active-minibuffer-window)
      (exwm-workspace--hide-minibuffer))
    (when exwm-workspace--display-echo-area-timer
      (cancel-timer exwm-workspace--display-echo-area-timer)
      (setq exwm-workspace--display-echo-area-timer nil))))

(defvar exwm-workspace--client nil
  "The 'client' frame parameter of emacsclient frames.")

(declare-function exwm-manage--unmanage-window "exwm-manage.el")
(declare-function exwm--exit "exwm.el")

(defun exwm-workspace--confirm-kill-emacs (prompt)
  "Confirm before exiting Emacs."
  (when (pcase (length exwm--id-buffer-alist)
          (0 (y-or-n-p prompt))
          (x (yes-or-no-p (format "[EXWM] %d window%s currently alive. %s"
                                  x (if (= x 1) "" "s") prompt))))
    ;; Unmanage all X windows.
    (dolist (i exwm--id-buffer-alist)
      (exwm-manage--unmanage-window (car i) 'quit)
      (xcb:+request exwm--connection
          (make-instance 'xcb:MapWindow :window (car i))))
    ;; Reparent out the minibuffer frame.
    (when (exwm-workspace--minibuffer-own-frame-p)
      (xcb:+request exwm--connection
          (make-instance 'xcb:ReparentWindow
                         :window (frame-parameter exwm-workspace--minibuffer
                                                  'exwm-outer-id)
                         :parent exwm--root
                         :x 0
                         :y 0)))
    ;; Reparent out all workspace frames.
    (dolist (f exwm-workspace--list)
      (xcb:+request exwm--connection
          (make-instance 'xcb:ReparentWindow
                         :window (frame-parameter f 'exwm-outer-id)
                         :parent exwm--root
                         :x 0
                         :y 0)))
    (xcb:flush exwm--connection)
    (if (not exwm-workspace--client)
        (progn
          ;; Destroy all resources created by this connection.
          (xcb:disconnect exwm--connection)
          t)
      ;; Extra cleanups for emacsclient.
      (dolist (f exwm-workspace--list)
        (set-frame-parameter f 'client exwm-workspace--client))
      (when (exwm-workspace--minibuffer-own-frame-p)
        (set-frame-parameter exwm-workspace--minibuffer 'client
                             exwm-workspace--client))
      (let ((connection exwm--connection))
        (exwm--exit)
        ;; Destroy all resources created by this connection.
        (xcb:disconnect connection))
      ;; Kill the client.
      (server-save-buffers-kill-terminal nil)
      nil)))

(defun exwm-workspace--set-desktop-geometry ()
  "Set _NET_DESKTOP_GEOMETRY."
  ;; We don't support large desktop so it's the same with screen size.
  (xcb:+request exwm--connection
      (make-instance 'xcb:ewmh:set-_NET_DESKTOP_GEOMETRY
                     :window exwm--root
                     :width (x-display-pixel-width)
                     :height (x-display-pixel-height))))

(defvar exwm-workspace--timer nil "Timer used to track echo area changes.")

(defun exwm-workspace--init ()
  "Initialize workspace module."
  (cl-assert (and (< 0 exwm-workspace-number) (>= 10 exwm-workspace-number)))
  ;; Prevent unexpected exit
  (setq confirm-kill-emacs #'exwm-workspace--confirm-kill-emacs)
  (if (not (exwm-workspace--minibuffer-own-frame-p))
      ;; Initialize workspaces with minibuffers.
      (progn
        (setq exwm-workspace--list (frame-list))
        (when (< 1 (length exwm-workspace--list))
          ;; Exclude the initial frame.
          (dolist (i exwm-workspace--list)
            (unless (frame-parameter i 'window-id)
              (setq exwm-workspace--list (delq i exwm-workspace--list))))
          (cl-assert (= 1 (length exwm-workspace--list)))
          (setq exwm-workspace--client
                (frame-parameter (car exwm-workspace--list) 'client))
          (let ((f (car exwm-workspace--list)))
            ;; Remove the possible internal border.
            (set-frame-parameter f 'internal-border-width 0)
            ;; Prevent user from deleting this frame by accident.
            (set-frame-parameter f 'client nil))
        ;; Create remaining frames.
        (dotimes (_ (1- exwm-workspace-number))
          (nconc exwm-workspace--list
                 (list (make-frame '((window-system . x)
                                     (internal-border-width . 0))))))))
    ;; Initialize workspaces without minibuffers.
    (let ((old-frames (frame-list)))
      (setq exwm-workspace--minibuffer
            (make-frame '((window-system . x) (minibuffer . only)
                          (left . 10000) (right . 10000)
                          (width . 0) (height . 0)
                          (internal-border-width . 0)
                          (client . nil))))
      ;; Remove/hide existing frames.
      (dolist (f old-frames)
        (if (frame-parameter f 'client)
            (progn
              (unless exwm-workspace--client
                (setq exwm-workspace--client (frame-parameter f 'client)))
              (make-frame-invisible f))
          (when (eq 'x (framep f))   ;do not delete the initial frame.
            (delete-frame f)))))
    ;; This is the only usable minibuffer frame.
    (setq default-minibuffer-frame exwm-workspace--minibuffer)
    (let ((outer-id (string-to-number
                     (frame-parameter exwm-workspace--minibuffer
                                      'outer-window-id)))
          (container (xcb:generate-id exwm--connection)))
      (set-frame-parameter exwm-workspace--minibuffer 'exwm-outer-id outer-id)
      (set-frame-parameter exwm-workspace--minibuffer 'exwm-container
                           container)
      (xcb:+request exwm--connection
          (make-instance 'xcb:CreateWindow
                         :depth 0 :wid container :parent exwm--root
                         :x -1 :y -1 :width 1 :height 1
                         :border-width 0 :class xcb:WindowClass:CopyFromParent
                         :visual 0        ;CopyFromParent
                         :value-mask xcb:CW:OverrideRedirect
                         :override-redirect 1))
      (exwm--debug
       (xcb:+request exwm--connection
           (make-instance 'xcb:ewmh:set-_NET_WM_NAME
                          :window container
                          :data "Minibuffer container")))
      (xcb:+request exwm--connection
          (make-instance 'xcb:ReparentWindow
                         :window outer-id :parent container :x 0 :y 0))
      ;; Attach event listener for monitoring the frame
      (xcb:+request exwm--connection
          (make-instance 'xcb:ChangeWindowAttributes
                         :window outer-id
                         :value-mask xcb:CW:EventMask
                         :event-mask xcb:EventMask:StructureNotify))
      (xcb:+event exwm--connection 'xcb:ConfigureNotify
                  #'exwm-workspace--on-ConfigureNotify))
    ;; Show/hide minibuffer / echo area when they're active/inactive.
    (add-hook 'minibuffer-setup-hook #'exwm-workspace--on-minibuffer-setup)
    (add-hook 'minibuffer-exit-hook #'exwm-workspace--on-minibuffer-exit)
    (setq exwm-workspace--timer
          (run-with-idle-timer 0 t #'exwm-workspace--on-echo-area-dirty))
    (add-hook 'echo-area-clear-hook #'exwm-workspace--on-echo-area-clear)
    ;; Create workspace frames.
    (dotimes (_ exwm-workspace-number)
      (push (make-frame `((window-system . x)
                          (minibuffer . ,(minibuffer-window
                                          exwm-workspace--minibuffer))
                          (internal-border-width . 0)
                          (client . nil)))
            exwm-workspace--list))
    ;; The default behavior of `display-buffer' (indirectly called by
    ;; `minibuffer-completion-help') is not correct here.
    (cl-pushnew '(exwm-workspace--display-buffer) display-buffer-alist
                :test #'equal))
  ;; Handle unexpected frame switch.
  (add-hook 'focus-in-hook #'exwm-workspace--on-focus-in)
  ;; Prevent `other-buffer' from selecting already displayed EXWM buffers.
  (modify-all-frames-parameters
   '((buffer-predicate . exwm-layout--other-buffer-predicate)))
  ;; Configure workspaces
  (dolist (i exwm-workspace--list)
    (let ((outer-id (string-to-number (frame-parameter i 'outer-window-id)))
          (container (xcb:generate-id exwm--connection))
          (workspace (xcb:generate-id exwm--connection)))
      ;; Save window IDs
      (set-frame-parameter i 'exwm-outer-id outer-id)
      (set-frame-parameter i 'exwm-container container)
      (set-frame-parameter i 'exwm-workspace workspace)
      (xcb:+request exwm--connection
          (make-instance 'xcb:CreateWindow
                         :depth 0 :wid workspace :parent exwm--root
                         :x 0 :y 0
                         :width (x-display-pixel-width)
                         :height (x-display-pixel-height)
                         :border-width 0 :class xcb:WindowClass:CopyFromParent
                         :visual 0      ;CopyFromParent
                         :value-mask (logior xcb:CW:OverrideRedirect
                                             xcb:CW:EventMask)
                         :override-redirect 1
                         :event-mask xcb:EventMask:SubstructureRedirect))
      (xcb:+request exwm--connection
          (make-instance 'xcb:CreateWindow
                         :depth 0 :wid container :parent workspace
                         :x 0 :y 0
                         :width (x-display-pixel-width)
                         :height (x-display-pixel-height)
                         :border-width 0 :class xcb:WindowClass:CopyFromParent
                         :visual 0      ;CopyFromParent
                         :value-mask xcb:CW:OverrideRedirect
                         :override-redirect 1))
      (exwm--debug
       (xcb:+request exwm--connection
           (make-instance 'xcb:ewmh:set-_NET_WM_NAME
                          :window workspace
                          :data
                          (format "EXWM workspace %d"
                                  (cl-position i exwm-workspace--list))))
       (xcb:+request exwm--connection
           (make-instance 'xcb:ewmh:set-_NET_WM_NAME
                          :window container
                          :data
                          (format "EXWM workspace %d frame container"
                                  (cl-position i exwm-workspace--list)))))
      (xcb:+request exwm--connection
          (make-instance 'xcb:ReparentWindow
                         :window outer-id :parent container :x 0 :y 0))
      (xcb:+request exwm--connection
          (make-instance 'xcb:MapWindow :window container))
      (xcb:+request exwm--connection
          (make-instance 'xcb:MapWindow :window workspace))))
  (xcb:flush exwm--connection)
  ;; We have to advice `x-create-frame' or every call to it would hang EXWM
  (advice-add 'x-create-frame :around #'exwm-workspace--x-create-frame)
  ;; Set _NET_NUMBER_OF_DESKTOPS (it's currently fixed).
  (xcb:+request exwm--connection
      (make-instance 'xcb:ewmh:set-_NET_NUMBER_OF_DESKTOPS
                     :window exwm--root :data exwm-workspace-number))
  ;; Set _NET_DESKTOP_GEOMETRY.
  (exwm-workspace--set-desktop-geometry)
  ;; Set _NET_DESKTOP_VIEWPORT (we don't support large desktop).
  (xcb:+request exwm--connection
      (make-instance 'xcb:ewmh:set-_NET_DESKTOP_VIEWPORT
                     :window exwm--root
                     :data (make-vector (* 2 exwm-workspace-number) 0)))
  ;; Update and set _NET_WORKAREA.
  (exwm-workspace--update-workareas)
  ;; Set _NET_VIRTUAL_ROOTS (it's currently fixed.)
  (xcb:+request exwm--connection
      (make-instance 'xcb:ewmh:set-_NET_VIRTUAL_ROOTS
                     :window exwm--root
                     :data (vconcat (mapcar
                                     (lambda (i)
                                       (frame-parameter i 'exwm-workspace))
                                     exwm-workspace--list))))
  ;; Switch to the first workspace
  (exwm-workspace-switch 0 t))

(defun exwm-workspace--exit ()
  "Exit the workspace module."
  (setq confirm-kill-emacs nil
        exwm-workspace--list nil
        exwm-workspace--client nil
        exwm-workspace--minibuffer nil
        default-minibuffer-frame nil)
  (remove-hook 'minibuffer-setup-hook #'exwm-workspace--on-minibuffer-setup)
  (remove-hook 'minibuffer-exit-hook #'exwm-workspace--on-minibuffer-exit)
  (when exwm-workspace--timer
    (cancel-timer exwm-workspace--timer)
    (setq exwm-workspace--timer nil))
  (remove-hook 'echo-area-clear-hook #'exwm-workspace--on-echo-area-clear)
  (setq display-buffer-alist
        (cl-delete '(exwm-workspace--display-buffer) display-buffer-alist
                   :test #'equal))
  (remove-hook 'focus-in-hook #'exwm-workspace--on-focus-in)
  (advice-remove 'x-create-frame #'exwm-workspace--x-create-frame))

(defun exwm-workspace--post-init ()
  "The second stage in the initialization of the workspace module."
  ;; Make the workspaces fullscreen.
  (dolist (i exwm-workspace--list)
    (set-frame-parameter i 'fullscreen 'fullboth))
  ;; Wait until all workspace frames are resized.
  (with-timeout (1)
    (while (< exwm-workspace--fullscreen-frame-count exwm-workspace-number)
      (accept-process-output nil 0.1)))
  (setq exwm-workspace--fullscreen-frame-count nil))



(provide 'exwm-workspace)

;;; exwm-workspace.el ends here
