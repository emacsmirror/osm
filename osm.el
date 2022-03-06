;;; osm.el --- OpenStreetMap viewer -*- lexical-binding: t -*-

;; Copyright (C) 2022 Daniel Mendler

;; Author: Daniel Mendler <mail@daniel-mendler.de>
;; Created: 2022
;; License: GPL-3.0-or-later
;; Version: 0.1
;; Package-Requires: ((emacs "27.1"))
;; Homepage: https://github.com/minad/osm

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; OpenStreetMap viewer

;;; Code:

(require 'seq)
(eval-when-compile (require 'cl-lib))

(defgroup osm nil
  "OpenStreetMap."
  :group 'network
  :prefix "osm-")

(defcustom osm-server-list
  '((default
     :name "OpenStreetMap"
     :min-zoom 2 :max-zoom 19 :max-connections 2
     :url "https://[abc].tile.openstreetmap.org/%z/%x/%y.png")
    (de
     :name "OSM Deutschland"
     :min-zoom 2 :max-zoom 19 :max-connections 2
     :url "https://[abc].tile.openstreetmap.de/%z/%x/%y.png")
    (fr
     :name "OSM France"
     :min-zoom 2 :max-zoom 19 :max-connections 2
     :url "https://[abc].tile.openstreetmap.fr/osmfr/%z/%x/%y.png")
    (humanitarian
     :name "OSM Humanitarian"
     :min-zoom 2 :max-zoom 19 :max-connections 2
     :url "https://[abc].tile.openstreetmap.fr/hot/%z/%x/%y.png")
    (opentopomap
     :name "OpenTopoMap"
     :min-zoom 2 :max-zoom 17 :max-connections 2
     :url "https://[abc].tile.opentopomap.org/%z/%x/%y.png")
    (opvnkarte
     :name "ÖPNVKarte"
     :min-zoom 2 :max-zoom 18 :max-connections 2
     :url "http://[abc].tile.memomaps.de/tilegen/%z/%x/%y.png")
    (cyclosm
     :name "CyclOSM"
     :min-zoom 2 :max-zoom 19 :max-connections 2
     :url "https://[abc].tile.openstreetmap.fr/cyclosm/%z/%x/%y.png")
    (openriverboatmap
     :name "OpenRiverBoatMap"
     :min-zoom 2 :max-zoom 19 :max-connections 2
     :url "https://[abc].tile.openstreetmap.fr/openriverboatmap/%z/%x/%y.png")
    (stamen-watercolor
     :name "Stamen Watercolor"
     :min-zoom 2 :max-zoom 19 :max-connections 2
     :url "https://stamen-tiles-[abc].a.ssl.fastly.net/watercolor/%z/%x/%y.jpg")
    (stamen-terrain
     :name "Stamen Terrain"
     :min-zoom 2 :max-zoom 18 :max-connections 2
     :url "https://stamen-tiles-[abc].a.ssl.fastly.net/terrain/%z/%x/%y.png")
    (stamen-toner
     :name "Stamen Toner"
     :min-zoom 2 :max-zoom 19 :max-connections 2
     :url "https://stamen-tiles-[abc].a.ssl.fastly.net/toner/%z/%x/%y.png"))
  "List of tile servers."
  :type '(alist :key-type symbol :value-type plist))

(defcustom osm-large-step 256
  "Movement step in pixel."
  :type 'integer)

(defcustom osm-small-step 16
  "Movement step in pixel."
  :type 'integer)

(defcustom osm-server 'default
  "Tile server name."
  :type 'symbol)

(defcustom osm-cache-directory
  (file-name-concat user-emacs-directory "var/osm/")
  "Tile cache directory."
  :type 'string)

(defcustom osm-max-age (* 60 60 24 14)
  "Maximum tile age.
Should be at least 7 days according to the server usage policies."
  :type '(choice (const nil) integer))

(defvar osm-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "+" #'osm-larger)
    (define-key map "-" #'osm-smaller)
    (define-key map [mouse-1] #'osm-click)
    (define-key map [drag-mouse-1] #'osm-drag)
    (define-key map [up] #'osm-up)
    (define-key map [down] #'osm-down)
    (define-key map [left] #'osm-left)
    (define-key map [right] #'osm-right)
    (define-key map [C-up] #'osm-up-large)
    (define-key map [C-down] #'osm-down-large)
    (define-key map [C-left] #'osm-left-large)
    (define-key map [C-right] #'osm-right-large)
    (define-key map [M-up] #'osm-up-large)
    (define-key map [M-down] #'osm-down-large)
    (define-key map [M-left] #'osm-left-large)
    (define-key map [M-right] #'osm-right-large)
    (define-key map "c" #'clone-buffer)
    (define-key map "h" #'osm-home)
    (define-key map "g" #'osm-goto)
    (define-key map "s" #'osm-search)
    (define-key map "S" #'osm-server)
    (define-key map "b" #'bookmark-set)
    (define-key map "B" #'bookmark-jump)
    (define-key map [remap scroll-down-command] #'osm-down)
    (define-key map [remap scroll-up-command] #'osm-up)
    (define-key map "\d" nil)
    (define-key map (kbd "S-SPC") nil)
    (define-key map " " nil)
    (define-key map "<" nil)
    (define-key map ">" nil)
    map)
  "Keymap used by `osm-mode'.")

(defconst osm--placeholder1
  `(image :type xbm :width 256 :height 256
          :data ,(make-bool-vector (* 256 256) nil))
  "First placeholder image for tiles.")

(defconst osm--placeholder2 `(image ,@(cdr osm--placeholder1))
  "Second placeholder image for tiles.
We need two distinct images which are not `eq' for the display properties.")

(defvar osm--search-history nil
  "Minibuffer search history used by `osm-search'.")

(defvar osm--clean-cache 0
  "Last time the tile cache was cleaned.")

(defvar-local osm--url-index 0
  "Current url index to query the servers in a round-robin fashion.")

(defvar-local osm--queue nil
  "Download queue of tiles.")

(defvar-local osm--active nil
  "Active download jobs.")

(defvar-local osm--wx 0
  "Half window width in pixel.")

(defvar-local osm--wy 0
  "Half window height in pixel.")

(defvar-local osm--nx 0
  "Number of tiles in x diretion.")

(defvar-local osm--ny 0
  "Number of tiles in y direction.")

(defvar-local osm--zoom nil
  "Zoom level of the map.")

(defvar-local osm--x nil
  "Y coordinate on the map in pixel.")

(defvar-local osm--y nil
  "X coordinate on the map in pixel.")

(defun osm--boundingbox-to-zoom (lat1 lat2 lon1 lon2)
  "Compute zoom level from boundingbox LAT1 to LAT2 and LON1 to LON2."
  (let ((w (/ (frame-pixel-width) 256))
        (h (/ (frame-pixel-height) 256)))
    (max (osm--server-property :min-zoom)
         (min
          (osm--server-property :max-zoom)
          (min (logb (/ w (abs (- (osm--lon-to-x lon1) (osm--lon-to-x lon2)))))
               (logb (/ h (abs (- (osm--lat-to-y lat1) (osm--lat-to-y lat2))))))))))

(defun osm--lon-to-x (lon)
  "Convert LON to x coordinate (unscaled)."
  (/ (+ lon 180.0) 360.0))

(defun osm--lat-to-y (lat)
  "Convert LAT to y coordiate (unscaled)."
  (setq lat (* lat (/ float-pi 180.0)))
  (- 0.5 (/ (log (+ (tan lat) (/ 1 (cos lat)))) float-pi 2)))

(defun osm--set-lat-lon (lat lon)
  "Set longitude LON and latitude LAT."
  (let ((n (* 256 (expt 2.0 osm--zoom))))
    (setq osm--x (floor (* n (osm--lon-to-x lon)))
          osm--y (floor (* n (osm--lat-to-y lat))))))

(defun osm--lon ()
  "Return longitude in degrees."
  (- (/ (* osm--x 360.0) 256.0 (expt 2.0 osm--zoom)) 180.0))

(defun osm--lat ()
  "Return latitude in degrees."
  (let ((y (* float-pi (- 1 (* 2 (/ osm--y 256.0 (expt 2.0 osm--zoom)))))))
    (/ (* 180 (atan (/ (- (exp y) (exp (- y))) 2))) float-pi)))

(defun osm--server-property (prop)
  "Return server property PROP."
  (plist-get (alist-get osm-server osm-server-list) prop))

(defun osm--tile-url (x y zoom)
  "Return tile url for coordinate X, Y and ZOOM."
  (let ((url (osm--server-property :url))
        (count 1))
    (save-match-data
      (when (string-match "\\`\\(.*\\)\\[\\(.*\\)\\]\\(.*\\)\\'" url)
        (setq count (- (match-end 2) (match-beginning 2))
              url (concat (match-string 1 url)
                          (char-to-string (aref (match-string 2 url) osm--url-index))
                          (match-string 3 url)))))
    (prog1
        (format-spec url `((?z . ,zoom) (?x . ,x) (?y . ,y)))
      (setq osm--url-index (mod (1+ osm--url-index) count)))))

(defun osm--tile-file (x y zoom)
  "Return tile file name for coordinate X, Y and ZOOM."
  (expand-file-name
   (format "%s%s/%d-%d-%d.%s"
           osm-cache-directory
           (symbol-name osm-server)
           zoom x y
           (file-name-extension
            (url-file-nondirectory
             (osm--server-property :url))))))

(defun osm--enqueue (x y)
  "Enqueue tile X/Y for download."
  (let ((job `(,x ,y . ,osm--zoom)))
    (unless (or (member job osm--queue) (member job osm--active))
      (setq osm--queue (nconc osm--queue (list job))))))

(defun osm--download ()
  "Download next tile in queue."
  (when-let (job (and (< (length osm--active)
                         (* (save-match-data
                              (if (string-match "\\[\\(.*\\)\\]"
                                                (osm--server-property :url))
                                  (- (match-end 1) (match-beginning 1)) 1))
                            (osm--server-property :max-connections)))
                      (pop osm--queue)))
    (push job osm--active)
    (pcase-let* ((`(,x ,y . ,zoom) job)
                 (buffer (current-buffer))
                 (dst (osm--tile-file x y zoom))
                 (tmp (concat dst ".tmp"))
                 (dir (file-name-directory tmp)))
      (unless (file-exists-p dir)
        (make-directory dir t))
      (make-process
       :name (format "osm %s %s %s" x y zoom)
       :connection-type 'pipe
       :noquery t
       :command
       (list "curl" "-s" "-o" tmp (osm--tile-url x y zoom))
       :filter #'ignore
       :sentinel
       (lambda (_proc status)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (and (string-match-p "finished" status)
                        (eq osm--zoom zoom))
               (ignore-errors (rename-file tmp dst t))
               (osm--display-tile x y))
             (delete-file tmp)
             (force-mode-line-update)
             (setq osm--active (delq job osm--active))
             (osm--download)))))
      (osm--download))))

(defun osm-click (event)
  "Handle click EVENT."
  (interactive "e")
  (pcase-let ((`(,x . ,y) (posn-x-y (event-start event))))
    (when (< osm--zoom (osm--server-property :max-zoom))
      (cl-incf osm--x (- x osm--wx))
      (cl-incf osm--y (- y osm--wy))
      (osm-larger))))

(defun osm-drag (event)
  "Handle drag EVENT."
  (interactive "e")
  (pcase-let ((`(,sx . ,sy) (posn-x-y (event-start event)))
              (`(,ex . ,ey) (posn-x-y (event-end event))))
    (cl-incf osm--x (- sx ex))
    (cl-incf osm--y (- sy ey))
    (osm--update)))

(defun osm-larger (&optional n)
  "Zoom N times into the map."
  (interactive "p")
  (setq n (or n 1))
  (cl-loop for i from n above 0
           if (< osm--zoom (osm--server-property :max-zoom)) do
           (setq osm--zoom (1+ osm--zoom)
                 osm--x (* osm--x 2)
                 osm--y (* osm--y 2)))
  (cl-loop for i from n below 0
           if (> osm--zoom (osm--server-property :min-zoom)) do
           (setq osm--zoom (1- osm--zoom)
                 osm--x (/ osm--x 2)
                 osm--y (/ osm--y 2)))
  (osm--update))

(defun osm-smaller (&optional n)
  "Zoom N times out of the map."
  (interactive "p")
  (osm-larger (- (or n 1))))

(defun osm--move (dx dy step)
  "Move by DX/DY with STEP size."
  (setq
   osm--x (min (* 256 (1- (expt 2 osm--zoom)))
               (max 0 (+ osm--x (* dx step))))
   osm--y (min (* 256 (1- (expt 2 osm--zoom)))
               (max 0 (+ osm--y (* dy step)))))
  (osm--update))

(defun osm-right (&optional n)
  "Move N small stepz to the right."
  (interactive "p")
  (osm--move (or n 1) 0 osm-small-step))

(defun osm-down (&optional n)
  "Move N small stepz down."
  (interactive "p")
  (osm--move 0 (or n 1) osm-small-step))

(defun osm-up (&optional n)
  "Move N small stepz up."
  (interactive "p")
  (osm-down (- (or n 1))))

(defun osm-left (&optional n)
  "Move N small stepz to the left."
  (interactive "p")
  (osm-right (- (or n 1))))

(defun osm-right-large (&optional n)
  "Move N large stepz to the right."
  (interactive "p")
  (osm--move (or n 1) 0 osm-large-step))

(defun osm-down-large (&optional n)
  "Move N large stepz down."
  (interactive "p")
  (osm--move 0 (or n 1) osm-large-step))

(defun osm-up-large (&optional n)
  "Move N large stepz up."
  (interactive "p")
  (osm-down-large (- (or n 1))))

(defun osm-left-large (&optional n)
  "Move N large stepz to the left."
  (interactive "p")
  (osm-right-large (- (or n 1))))

(defun osm--clean-cache ()
  "Clean tile cache."
  (when (and (integerp osm-max-age)
             (> (- (float-time) osm--clean-cache) osm-max-age))
    (setq osm--clean-cache (float-time))
    (run-with-idle-timer
     30 nil
     (lambda ()
       (dolist (file
                (ignore-errors
                  (directory-files-recursively
                   osm-cache-directory
                   "\\.\\(?:png\\|jpe?g\\)\\(?:\\.tmp\\)?\\'" nil)))
         (when (> (float-time
                   (time-since
                    (file-attribute-modification-time
                     (file-attributes file))))
                  osm-max-age)
           (delete-file file)))))))

(define-derived-mode osm-mode special-mode "Osm"
  "Open Street Map mode."
  :interactive nil
  (osm--clean-cache)
  (setq-local osm-server osm-server
              line-spacing nil
              cursor-type nil
              cursor-in-non-selected-windows nil
              left-fringe-width 1
              right-fringe-width 1
              left-margin-width 0
              right-margin-width 0
              truncate-lines t
              show-trailing-whitespace nil
              display-line-numbers nil
              buffer-read-only t
              fringe-indicator-alist '((truncation . nil))
              revert-buffer-function #'osm--revert
              mwheel-scroll-up-function #'osm-down
              mwheel-scroll-down-function #'osm-up
              mwheel-scroll-left-function #'osm-left
              mwheel-scroll-right-function #'osm-right
              bookmark-make-record-function #'osm--make-bookmark)
  (add-hook 'window-size-change-functions #'osm--revert nil 'local))

(defun osm--display-tile (x y)
  "Display tile at X/Y."
  (let ((i (- x (/ (- osm--x osm--wx) 256)))
        (j (- y (/ (- osm--y osm--wy) 256))))
    (when (and (>= i 0) (< i osm--nx) (>= j 0) (< j osm--ny))
      (let* ((mx (if (= 0 i) (mod (- osm--x osm--wx) 256) 0))
             (my (if (= 0 j) (mod (- osm--y osm--wy) 256) 0))
             (pos (+ (point-min) (* j (1+ osm--nx)) i))
             (file (osm--tile-file x y osm--zoom))
             (image (cond
                     ((file-exists-p file)
                      `(image :type
                              ,(if (member (file-name-extension file) '("jpg" "jpeg"))
                                   'jpeg 'png)
                              :file ,file
                              :width 256 :height 256))
                     ((= 0 (mod i 2)) osm--placeholder1)
                     (t osm--placeholder2))))
        (with-silent-modifications
          (put-text-property
           pos (1+ pos) 'display
           (if (or (/= 0 mx) (/= 0 my))
               `((slice ,mx ,my ,(- 256 mx) ,(- 256 my)) ,image)
             image)))))))

;;;###autoload
(defun osm-home ()
  "New OSM buffer."
  (interactive)
  (let ((lat (bound-and-true-p calendar-latitude))
        (lon (bound-and-true-p calendar-longitude))
        (zoom 11))
    (unless (and lat lon)
      (setq lat 0 lon 0 zoom 2))
    (osm-goto lat lon zoom)))

(defun osm--queue-info ()
  "Return queue info string."
  (let ((n (length osm--queue)))
    (when (> n 0)
      (format "(%s/%s)" (length osm--active) n))))

(defun osm--revert (&rest _)
  "Revert buffer."
  (when (derived-mode-p #'osm-mode)
    (osm--update)))

(defun osm--update ()
  "Update map display."
  (unless (derived-mode-p #'osm-mode)
    (error "Not an osm-mode buffer"))
  (with-silent-modifications
    (let* ((size (expt 2 osm--zoom))
           (meter-per-pixel (/ (* 156543.03 (cos (/ (osm--lat) (/ 180.0 float-pi)))) size))
           (meter '(1 5 10 50 100 500 1000 5000 10000 50000 100000 500000 1000000 5000000 10000000))
           (idx 0))
      (while (and (< idx (1- (length meter))) (< (/ (nth (1+ idx) meter) meter-per-pixel) 100))
        (cl-incf idx))
      (setq meter (nth idx meter))
      (setq-local
       header-line-format
       (list
        (format " %s %s %s    Z%-2d    %s%s%s %s %s    "
                (osm--server-property :name)
                (format #("%7.2f°" 0 5 (face bold)) (osm--lat))
                (format #("%7.2f°" 0 5 (face bold)) (osm--lon))
                osm--zoom
                (propertize " " 'face '(:inverse-video t)
                            'display '(space :width (3)))
                (propertize " " 'face '(:strike-through t)
                            'display `(space :width (,(floor (/ meter meter-per-pixel)))))
                (propertize " " 'face '(:inverse-video t)
                            'display '(space :width (3)))
                (if (>= meter 1000) (/ meter 1000) meter)
                (if (>= meter 1000) "km" "m"))
        '(:eval (osm--queue-info))))
      (setq osm--wx (/ (window-pixel-width) 2)
            osm--wy (/ (window-pixel-height) 2)
            osm--nx (1+ (ceiling (window-pixel-width) 256))
            osm--ny (1+ (ceiling (window-pixel-height) 256)))
      (erase-buffer)
      (dotimes (_j osm--ny)
        (insert (concat (make-string osm--nx ?\s) "\n")))
      (goto-char (point-min))
      (dotimes (j osm--ny)
        (dotimes (i osm--nx)
          (let ((x (+ i (/ (- osm--x osm--wx) 256)))
                (y (+ j (/ (- osm--y osm--wy) 256))))
            (osm--display-tile x y)
            (when (and (>= x 0) (>= y 0) (< x size) (< y size)
                       (not (file-exists-p (osm--tile-file x y osm--zoom))))
              (osm--enqueue x y)))))
      (setq osm--queue
            (seq-sort-by
             (pcase-lambda (`(,x ,y . ,_z))
               (setq x (- x (/ osm--x 256))
                     y (- y (/ osm--y 256)))
               (+ (* x x) (* y y)))
             #'< osm--queue))
      (osm--download))))

(declare-function bookmark-make-record-default "boomark")
(defun osm--make-bookmark ()
  "Make OSM bookmark."
  `(,(osm--bookmark-name)
    ,@(bookmark-make-record-default t)
    (lon . ,(osm--lon))
    (lat . ,(osm--lat))
    (zoom . ,osm--zoom)
    (name . ,(buffer-name))
    (handler . ,#'osm-bookmark-jump)))

;;;###autoload
(defun osm-goto (lat lon zoom &optional name)
  "Goto LAT/LON/ZOOM in buffer NAME."
  (interactive
   (pcase-let ((`(,lat ,lon ,zoom) (mapcar #'string-to-number (split-string (read-string "Lat Lon (Zoom): ") nil t))))
     (setq zoom (or zoom 11))
     (unless (and (numberp lat) (numberp lon) (numberp zoom))
       (error "Invalid coordindate"))
     (list lat lon zoom)))
  (with-current-buffer
      (if (and (not name) (derived-mode-p #'osm-mode))
          (current-buffer)
        (generate-new-buffer (or name (osm--buffer-name))))
    (unless (derived-mode-p #'osm-mode)
      (osm-mode))
    (setq osm--zoom zoom)
    (osm--set-lat-lon lat lon)
    (if (get-buffer-window)
        (osm--update)
      (pop-to-buffer (current-buffer)))))

(defun osm--buffer-name ()
  "Return buffer name."
  (format "*osm: %s*" (osm--server-property :name)))

;;;###autoload
(defun osm-bookmark-jump (bm)
  "Jump to OSM bookmark BM."
  (osm-goto
   (alist-get 'lat bm)
   (alist-get 'lon bm)
   (alist-get 'zoom bm)
   (unless (derived-mode-p #'osm-mode)
     (alist-get 'name bm))))

(defun osm--bookmark-name ()
  "Return bookmark name for current map."
  (format "OSM: %s%.2f° %.2f°"
          (concat (osm--description) " ")
          (osm--lat)
          (osm--lon)))

(defun osm--link-data ()
  "Return link data."
  (list (osm--lat) (osm--lon) osm--zoom (osm--description)))

(defun osm--description ()
  "Return descriptive string for current map."
  (alist-get
   'display_name
   (json-parse-string
    (shell-command-to-string
     (concat
      "curl -s "
      (shell-quote-argument
       (format "https://nominatim.openstreetmap.org/reverse?format=json&zoom=%s&lon=%s&lat=%s"
               (min 18 (max 3 osm--zoom)) (osm--lon) (osm--lat)))))
    :array-type 'list
    :object-type 'alist)))

;;;###autoload
(defun osm-search ()
  "Search for location and display the map."
  (interactive)
  ;; TODO add search bounded to current viewbox, bounded=1, viewbox=x1,y1,x2,y2
  (let* ((search (completing-read
                  "Location: " osm--search-history
                  nil nil nil 'osm--search-history))
         (json (json-parse-string
                (shell-command-to-string
                 (concat "curl -s "
                         (shell-quote-argument
                          (concat "https://nominatim.openstreetmap.org/search?format=json&q="
                                  (url-encode-url search)))))
                :array-type 'list
                :object-type 'alist))
         (results (mapcar
                   (lambda (x)
                     `(,(format "%s (%s° %s°)"
                                (alist-get 'display_name x)
                                (alist-get 'lat x)
                                (alist-get 'lon x))
                       ,(string-to-number (alist-get 'lat x))
                       ,(string-to-number (alist-get 'lon x))
                       ,@(mapcar #'string-to-number (alist-get 'boundingbox x))))
                   (or json (error "No results"))))
         (selected (or (cdr (assoc
                             (completing-read
                              (format "Matches for '%s': " search)
                              results nil t nil t)
                             results))
                       (error "No selection"))))
    (osm-goto (car selected) (cadr selected)
              (apply #'osm--boundingbox-to-zoom (cddr selected)))))

;;;###autoload
(defun osm-server (server)
  "Select SERVER."
  (interactive
   (list
    (let ((servers
           (mapcar
            (lambda (x)
              (cons (plist-get (cdr x) :name) (car x)))
            osm-server-list)))
      (or (cdr (assoc (completing-read
                       "Server: " servers nil t nil nil
                       (osm--server-property :name))
                      servers))
          (error "No server selected")))))
  (with-current-buffer
      (if (derived-mode-p #'osm-mode)
          (current-buffer)
        (osm-home))
    (unless (eq osm-server server)
      (let ((rename (string-match-p
                     (format "\\`\\*osm: %s\\*\\(?:<[0-9]+>\\)?\\'"
                             (regexp-quote (osm--server-property :name)))
                     (buffer-name))))
        (setq-local osm-server server
                    osm--active nil
                    osm--queue nil)
        (when rename (rename-buffer (osm--buffer-name) 'unique)))
      (osm--update))))

(dolist (sym (list #'osm-up #'osm-down #'osm-left #'osm-right
                   #'osm-up-large #'osm-down-large #'osm-left-large #'osm-right-large
                   #'osm-smaller #'osm-larger))
  (put sym 'command-modes '(osm-mode)))

(provide 'osm)
;;; osm.el ends here
