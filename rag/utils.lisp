;;;; utils.lisp
;;;; CL-Agent RAG - Vector Math and Text Utilities
;;;;
;;;; Overview:
;;;;   Common utility functions for RAG operations including
;;;;   vector math, text processing, and similarity metrics.

(in-package :cl-agent.rag)

;;; ============================================================
;;; Vector Math Utilities
;;; ============================================================

(defun cosine-similarity (vec1 vec2)
  "Calculate cosine similarity between two vectors.

Parameters:
  VEC1 - First vector (list or array)
  VEC2 - Second vector (list or array)

Returns:
  Similarity score between -1 and 1

Example:
  (cosine-similarity '(1 0 1) '(1 1 0)) => 0.5"
  (let ((v1 (coerce vec1 'vector))
        (v2 (coerce vec2 'vector)))
    (let ((dot-product (loop for a across v1
                             for b across v2
                             sum (* a b)))
          (norm1 (sqrt (loop for v across v1 sum (* v v))))
          (norm2 (sqrt (loop for v across v2 sum (* v v)))))
      (if (or (zerop norm1) (zerop norm2))
          0.0
          (/ dot-product (* norm1 norm2))))))

(defun euclidean-distance (vec1 vec2)
  "Calculate Euclidean distance between two vectors.

Parameters:
  VEC1 - First vector
  VEC2 - Second vector

Returns:
  Distance (non-negative real)"
  (let ((v1 (coerce vec1 'vector))
        (v2 (coerce vec2 'vector)))
    (sqrt (loop for a across v1
                for b across v2
                sum (expt (- a b) 2)))))

(defun dot-product (vec1 vec2)
  "Calculate dot product of two vectors.

Parameters:
  VEC1 - First vector
  VEC2 - Second vector

Returns:
  Scalar dot product"
  (let ((v1 (coerce vec1 'vector))
        (v2 (coerce vec2 'vector)))
    (loop for a across v1
          for b across v2
          sum (* a b))))

(defun vector-norm (vec)
  "Calculate L2 norm of a vector.

Parameters:
  VEC - Input vector

Returns:
  L2 norm (magnitude)"
  (let ((v (coerce vec 'vector)))
    (sqrt (loop for x across v sum (* x x)))))

(defun normalize-vector (vec)
  "Normalize a vector to unit length.

Parameters:
  VEC - Input vector

Returns:
  Normalized vector (list)"
  (let* ((v (coerce vec 'vector))
         (norm (vector-norm v)))
    (if (zerop norm)
        (coerce v 'list)
        (loop for x across v
              collect (/ x norm)))))

(defun manhattan-distance (vec1 vec2)
  "Calculate Manhattan (L1) distance between two vectors.

Parameters:
  VEC1 - First vector
  VEC2 - Second vector

Returns:
  L1 distance"
  (let ((v1 (coerce vec1 'vector))
        (v2 (coerce vec2 'vector)))
    (loop for a across v1
          for b across v2
          sum (abs (- a b)))))

(defun weighted-average-vectors (vectors weights)
  "Compute weighted average of vectors.

Parameters:
  VECTORS - List of vectors
  WEIGHTS - List of weights (should sum to 1)

Returns:
  Weighted average vector"
  (when (null vectors)
    (return-from weighted-average-vectors nil))
  (let* ((dim (length (first vectors)))
         (result (make-array dim :initial-element 0.0)))
    (loop for vec in vectors
          for w in weights
          do (loop for i from 0 below dim
                   do (incf (aref result i)
                            (* w (elt vec i)))))
    (coerce result 'list)))

;;; ============================================================
;;; Text Utilities
;;; ============================================================

(defun word-count (text)
  "Count words in text.

Parameters:
  TEXT - Input string

Returns:
  Number of words"
  (length (cl-ppcre:split "\\s+" (string-trim '(#\Space #\Tab #\Newline) text))))

(defun char-count (text)
  "Count characters in text (excluding whitespace).

Parameters:
  TEXT - Input string

Returns:
  Number of non-whitespace characters"
  (count-if-not (lambda (c)
                  (member c '(#\Space #\Tab #\Newline #\Return)))
                text))

(defun sentence-split (text)
  "Split text into sentences.

Parameters:
  TEXT - Input string

Returns:
  List of sentences"
  (let ((sentences (cl-ppcre:split "[.!?]+\\s*" text)))
    (remove-if (lambda (s) (zerop (length (string-trim '(#\Space #\Tab #\Newline) s))))
               sentences)))

(defun paragraph-split (text)
  "Split text into paragraphs.

Parameters:
  TEXT - Input string

Returns:
  List of paragraphs"
  (let ((paragraphs (cl-ppcre:split "\\n\\s*\\n+" text)))
    (remove-if (lambda (s) (zerop (length (string-trim '(#\Space #\Tab #\Newline) s))))
               paragraphs)))

(defun truncate-text (text max-length &key (ellipsis "..."))
  "Truncate text to maximum length.

Parameters:
  TEXT       - Input string
  MAX-LENGTH - Maximum length
  ELLIPSIS   - String to append if truncated

Returns:
  Truncated string"
  (if (<= (length text) max-length)
      text
      (concatenate 'string
                   (subseq text 0 (- max-length (length ellipsis)))
                   ellipsis)))

(defun clean-text (text)
  "Clean text by normalizing whitespace and removing control characters.

Parameters:
  TEXT - Input string

Returns:
  Cleaned string"
  (let ((cleaned (cl-ppcre:regex-replace-all "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]" text "")))
    (cl-ppcre:regex-replace-all "\\s+" cleaned " ")))

(defun extract-keywords (text &key (min-length 3) (max-count 20))
  "Extract keywords from text (simple frequency-based).

Parameters:
  TEXT       - Input string
  MIN-LENGTH - Minimum word length
  MAX-COUNT  - Maximum keywords to return

Returns:
  List of (word . frequency) pairs"
  (let ((words (cl-ppcre:split "\\W+" (string-downcase text)))
        (freq-table (make-hash-table :test 'equal)))
    ;; Count frequencies
    (dolist (word words)
      (when (>= (length word) min-length)
        (incf (gethash word freq-table 0))))
    ;; Sort by frequency
    (let ((pairs nil))
      (maphash (lambda (k v) (push (cons k v) pairs)) freq-table)
      (setf pairs (sort pairs #'> :key #'cdr))
      (subseq pairs 0 (min max-count (length pairs))))))

;;; ============================================================
;;; Scoring Utilities
;;; ============================================================

(defun reciprocal-rank-fusion (ranked-lists &key (k 60))
  "Combine multiple ranked lists using Reciprocal Rank Fusion.

Parameters:
  RANKED-LISTS - List of ranked lists, each containing items
  K            - Smoothing constant (default: 60)

Returns:
  Fused ranking as list of (item . score) pairs"
  (let ((scores (make-hash-table :test 'equal)))
    (dolist (ranked-list ranked-lists)
      (loop for item in ranked-list
            for rank from 1
            do (incf (gethash item scores 0.0)
                     (/ 1.0 (+ k rank)))))
    (let ((pairs nil))
      (maphash (lambda (k v) (push (cons k v) pairs)) scores)
      (sort pairs #'> :key #'cdr))))

(defun min-max-normalize (values)
  "Normalize values to [0, 1] range using min-max scaling.

Parameters:
  VALUES - List of numeric values

Returns:
  Normalized list"
  (when (null values)
    (return-from min-max-normalize nil))
  (let ((min-val (reduce #'min values))
        (max-val (reduce #'max values)))
    (if (= min-val max-val)
        (make-list (length values) :initial-element 0.5)
        (mapcar (lambda (v) (/ (- v min-val) (- max-val min-val))) values))))

(defun softmax (values &key (temperature 1.0))
  "Apply softmax function to values.

Parameters:
  VALUES      - List of numeric values
  TEMPERATURE - Temperature parameter (higher = more uniform)

Returns:
  Probability distribution (sums to 1)"
  (when (null values)
    (return-from softmax nil))
  (let* ((scaled (mapcar (lambda (v) (/ v temperature)) values))
         (max-val (reduce #'max scaled))
         (exps (mapcar (lambda (v) (exp (- v max-val))) scaled))
         (sum-exp (reduce #'+ exps)))
    (mapcar (lambda (e) (/ e sum-exp)) exps)))

;;; ============================================================
;;; Hash/ID Utilities
;;; ============================================================

(defun content-hash (text)
  "Generate a hash of text content.

Parameters:
  TEXT - Input string

Returns:
  Hash string"
  (format nil "~X" (sxhash text)))

(defun generate-chunk-id (content &optional parent-id index)
  "Generate a unique ID for a text chunk.

Parameters:
  CONTENT   - Chunk content
  PARENT-ID - Parent document ID
  INDEX     - Chunk index within parent

Returns:
  Unique chunk ID string"
  (if parent-id
      (format nil "~A-~A-~A" parent-id (or index 0) (content-hash content))
      (format nil "chunk-~A" (cl-agent.core:generate-uuid))))

