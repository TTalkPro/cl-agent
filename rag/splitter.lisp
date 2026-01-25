;;;; splitter.lisp
;;;; CL-Agent RAG - Text Chunking Strategies
;;;;
;;;; Overview:
;;;;   Text splitting/chunking for RAG pipeline with multiple
;;;;   strategies for different content types.

(in-package :cl-agent.rag)

;;; ============================================================
;;; Splitter Protocol
;;; ============================================================

(defgeneric split (splitter text)
  (:documentation "Split text into chunks using the splitter strategy.

Parameters:
  SPLITTER - Splitter instance
  TEXT     - Text to split

Returns:
  List of text chunks"))

(defgeneric splitter-metadata (splitter)
  (:documentation "Get metadata about the splitter configuration."))

;;; ============================================================
;;; Fixed Size Splitter
;;; ============================================================

(defclass fixed-size-splitter ()
  ((chunk-size
    :initarg :chunk-size
    :accessor splitter-chunk-size
    :initform 1000
    :type integer
    :documentation "Maximum chunk size in characters")

   (chunk-overlap
    :initarg :chunk-overlap
    :accessor splitter-chunk-overlap
    :initform 200
    :type integer
    :documentation "Overlap between consecutive chunks")

   (trim-whitespace
    :initarg :trim-whitespace
    :accessor splitter-trim-whitespace
    :initform t
    :type boolean
    :documentation "Whether to trim whitespace from chunks"))

  (:documentation "Fixed-size text splitter with overlap."))

(defun make-fixed-size-splitter (&key (chunk-size 1000) (chunk-overlap 200)
                                       (trim-whitespace t))
  "Create a fixed-size splitter.

Parameters:
  CHUNK-SIZE    - Maximum chunk size
  CHUNK-OVERLAP - Overlap between chunks
  TRIM-WHITESPACE - Whether to trim chunks

Returns:
  fixed-size-splitter instance"
  (make-instance 'fixed-size-splitter
                 :chunk-size chunk-size
                 :chunk-overlap chunk-overlap
                 :trim-whitespace trim-whitespace))

(defmethod split ((splitter fixed-size-splitter) text)
  "Split text into fixed-size chunks with overlap."
  (let ((chunks nil)
        (chunk-size (splitter-chunk-size splitter))
        (overlap (splitter-chunk-overlap splitter))
        (trim-p (splitter-trim-whitespace splitter))
        (text-len (length text))
        (pos 0))

    (loop while (< pos text-len)
          do (let* ((end (min (+ pos chunk-size) text-len))
                    (chunk (subseq text pos end)))
               (when trim-p
                 (setf chunk (string-trim '(#\Space #\Tab #\Newline #\Return) chunk)))
               (when (> (length chunk) 0)
                 (push chunk chunks))
               (setf pos (max (1+ pos) (- end overlap)))))

    (nreverse chunks)))

(defmethod splitter-metadata ((splitter fixed-size-splitter))
  (list :type :fixed-size
        :chunk-size (splitter-chunk-size splitter)
        :chunk-overlap (splitter-chunk-overlap splitter)))

;;; ============================================================
;;; Sentence Splitter
;;; ============================================================

(defclass sentence-splitter ()
  ((max-chunk-size
    :initarg :max-chunk-size
    :accessor splitter-max-chunk-size
    :initform 1000
    :type integer
    :documentation "Maximum chunk size - sentences are grouped up to this size")

   (sentence-endings
    :initarg :sentence-endings
    :accessor splitter-sentence-endings
    :initform '(#\. #\! #\? #\。 #\！ #\？)
    :type list
    :documentation "Characters that end sentences"))

  (:documentation "Sentence-aware text splitter."))

(defun make-sentence-splitter (&key (max-chunk-size 1000))
  "Create a sentence-based splitter."
  (make-instance 'sentence-splitter
                 :max-chunk-size max-chunk-size))

(defmethod split ((splitter sentence-splitter) text)
  "Split text into chunks at sentence boundaries."
  (let* ((max-size (splitter-max-chunk-size splitter))
         (endings (splitter-sentence-endings splitter))
         (sentences (split-into-sentences text endings))
         (chunks nil)
         (current-chunk ""))

    (dolist (sentence sentences)
      (let ((new-length (+ (length current-chunk)
                           (if (> (length current-chunk) 0) 1 0)
                           (length sentence))))
        (if (and (> (length current-chunk) 0)
                 (> new-length max-size))
            ;; Start new chunk
            (progn
              (push (string-trim '(#\Space #\Tab #\Newline) current-chunk) chunks)
              (setf current-chunk sentence))
            ;; Add to current chunk
            (setf current-chunk
                  (if (> (length current-chunk) 0)
                      (concatenate 'string current-chunk " " sentence)
                      sentence)))))

    ;; Add remaining chunk
    (when (> (length current-chunk) 0)
      (push (string-trim '(#\Space #\Tab #\Newline) current-chunk) chunks))

    (nreverse chunks)))

(defun split-into-sentences (text endings)
  "Split text into sentences based on ending characters."
  (let ((sentences nil)
        (current "")
        (text-len (length text)))
    (loop for i from 0 below text-len
          for char = (char text i)
          do (setf current (concatenate 'string current (string char)))
             (when (and (member char endings)
                        (or (= (1+ i) text-len)
                            (member (char text (1+ i)) '(#\Space #\Newline #\Tab))))
               (push (string-trim '(#\Space #\Tab #\Newline) current) sentences)
               (setf current "")))
    (when (> (length (string-trim '(#\Space) current)) 0)
      (push (string-trim '(#\Space #\Tab #\Newline) current) sentences))
    (nreverse sentences)))

(defmethod splitter-metadata ((splitter sentence-splitter))
  (list :type :sentence
        :max-chunk-size (splitter-max-chunk-size splitter)))

;;; ============================================================
;;; Paragraph Splitter
;;; ============================================================

(defclass paragraph-splitter ()
  ((max-chunk-size
    :initarg :max-chunk-size
    :accessor splitter-max-chunk-size
    :initform 2000
    :type integer
    :documentation "Maximum chunk size")

   (paragraph-separator
    :initarg :paragraph-separator
    :accessor splitter-paragraph-separator
    :initform "\\n\\s*\\n"
    :type string
    :documentation "Regex for paragraph separation"))

  (:documentation "Paragraph-aware text splitter."))

(defun make-paragraph-splitter (&key (max-chunk-size 2000))
  "Create a paragraph-based splitter."
  (make-instance 'paragraph-splitter
                 :max-chunk-size max-chunk-size))

(defmethod split ((splitter paragraph-splitter) text)
  "Split text into chunks at paragraph boundaries."
  (let* ((max-size (splitter-max-chunk-size splitter))
         (separator (splitter-paragraph-separator splitter))
         (paragraphs (cl-ppcre:split separator text))
         (chunks nil)
         (current-chunk ""))

    (dolist (para paragraphs)
      (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) para)))
        (when (> (length trimmed) 0)
          (let ((new-length (+ (length current-chunk)
                               (if (> (length current-chunk) 0) 2 0)
                               (length trimmed))))
            (if (and (> (length current-chunk) 0)
                     (> new-length max-size))
                ;; Start new chunk
                (progn
                  (push current-chunk chunks)
                  (setf current-chunk trimmed))
                ;; Add to current
                (setf current-chunk
                      (if (> (length current-chunk) 0)
                          (concatenate 'string current-chunk (string #\Newline) (string #\Newline) trimmed)
                          trimmed)))))))

    (when (> (length current-chunk) 0)
      (push current-chunk chunks))

    (nreverse chunks)))

(defmethod splitter-metadata ((splitter paragraph-splitter))
  (list :type :paragraph
        :max-chunk-size (splitter-max-chunk-size splitter)))

;;; ============================================================
;;; Recursive Character Splitter
;;; ============================================================

(defclass recursive-splitter ()
  ((chunk-size
    :initarg :chunk-size
    :accessor splitter-chunk-size
    :initform 1000
    :type integer)

   (chunk-overlap
    :initarg :chunk-overlap
    :accessor splitter-chunk-overlap
    :initform 200
    :type integer)

   (separators
    :initarg :separators
    :accessor splitter-separators
    :initform '("\\n\\n" "\\n" " " "")
    :type list
    :documentation "Separators to try in order"))

  (:documentation "Recursive character splitter - tries multiple separators."))

(defun make-recursive-splitter (&key (chunk-size 1000) (chunk-overlap 200)
                                      (separators '("\\n\\n" "\\n" " " "")))
  "Create a recursive character splitter."
  (make-instance 'recursive-splitter
                 :chunk-size chunk-size
                 :chunk-overlap chunk-overlap
                 :separators separators))

(defmethod split ((splitter recursive-splitter) text)
  "Split text recursively using multiple separators."
  (recursive-split text
                   (splitter-separators splitter)
                   (splitter-chunk-size splitter)
                   (splitter-chunk-overlap splitter)))

(defun recursive-split (text separators chunk-size chunk-overlap)
  "Internal recursive splitting function."
  (when (null separators)
    ;; No more separators, use fixed-size split
    (return-from recursive-split
      (split (make-fixed-size-splitter :chunk-size chunk-size
                                       :chunk-overlap chunk-overlap)
             text)))

  (let* ((separator (first separators))
         (parts (if (string= separator "")
                    (list text)
                    (cl-ppcre:split separator text))))

    (if (= (length parts) 1)
        ;; Separator didn't split, try next
        (recursive-split text (rest separators) chunk-size chunk-overlap)
        ;; Combine small parts, split large ones
        (let ((chunks nil)
              (current ""))
          (dolist (part parts)
            (let ((trimmed (string-trim '(#\Space #\Tab #\Newline) part)))
              (when (> (length trimmed) 0)
                (cond
                  ;; Part itself is too large
                  ((> (length trimmed) chunk-size)
                   (when (> (length current) 0)
                     (push current chunks)
                     (setf current ""))
                   (dolist (sub-chunk (recursive-split trimmed
                                                       (rest separators)
                                                       chunk-size
                                                       chunk-overlap))
                     (push sub-chunk chunks)))

                  ;; Would exceed chunk size
                  ((> (+ (length current)
                         (if (> (length current) 0) 1 0)
                         (length trimmed))
                      chunk-size)
                   (when (> (length current) 0)
                     (push current chunks))
                   (setf current trimmed))

                  ;; Add to current
                  (t
                   (setf current
                         (if (> (length current) 0)
                             (concatenate 'string current " " trimmed)
                             trimmed)))))))

          (when (> (length current) 0)
            (push current chunks))

          (nreverse chunks)))))

(defmethod splitter-metadata ((splitter recursive-splitter))
  (list :type :recursive
        :chunk-size (splitter-chunk-size splitter)
        :chunk-overlap (splitter-chunk-overlap splitter)
        :separators (splitter-separators splitter)))

;;; ============================================================
;;; Code Splitter
;;; ============================================================

(defclass code-splitter ()
  ((chunk-size
    :initarg :chunk-size
    :accessor splitter-chunk-size
    :initform 1500
    :type integer)

   (language
    :initarg :language
    :accessor splitter-language
    :initform :generic
    :type keyword
    :documentation "Programming language hint"))

  (:documentation "Code-aware splitter that respects function/class boundaries."))

(defun make-code-splitter (&key (chunk-size 1500) (language :generic))
  "Create a code-aware splitter."
  (make-instance 'code-splitter
                 :chunk-size chunk-size
                 :language language))

(defmethod split ((splitter code-splitter) text)
  "Split code respecting logical boundaries."
  (let ((separators (case (splitter-language splitter)
                      (:python '("\\n\\nclass " "\\n\\ndef " "\\n\\n" "\\n" " "))
                      (:javascript '("\\n\\nfunction " "\\n\\nclass " "\\n\\nconst " "\\n\\n" "\\n"))
                      (:lisp '("\\n\\n(def" "\\n\\n" "\\n"))
                      (:java '("\\n\\npublic " "\\n\\nprivate " "\\n\\n" "\\n"))
                      (otherwise '("\\n\\n" "\\n" " ")))))
    (recursive-split text separators
                     (splitter-chunk-size splitter)
                     0))) ; No overlap for code

(defmethod splitter-metadata ((splitter code-splitter))
  (list :type :code
        :chunk-size (splitter-chunk-size splitter)
        :language (splitter-language splitter)))

;;; ============================================================
;;; Markdown Splitter
;;; ============================================================

(defclass markdown-splitter ()
  ((chunk-size
    :initarg :chunk-size
    :accessor splitter-chunk-size
    :initform 1000
    :type integer)

   (heading-levels
    :initarg :heading-levels
    :accessor splitter-heading-levels
    :initform '(1 2 3)
    :type list
    :documentation "Heading levels to split on"))

  (:documentation "Markdown-aware splitter that respects heading structure."))

(defun make-markdown-splitter (&key (chunk-size 1000) (heading-levels '(1 2 3)))
  "Create a markdown-aware splitter."
  (make-instance 'markdown-splitter
                 :chunk-size chunk-size
                 :heading-levels heading-levels))

(defmethod split ((splitter markdown-splitter) text)
  "Split markdown respecting heading hierarchy."
  (let ((separators (append
                     (loop for level in (sort (copy-list (splitter-heading-levels splitter)) #'<)
                           collect (format nil "\\n~A " (make-string level :initial-element #\#)))
                     '("\\n\\n" "\\n"))))
    (recursive-split text separators
                     (splitter-chunk-size splitter)
                     100)))

(defmethod splitter-metadata ((splitter markdown-splitter))
  (list :type :markdown
        :chunk-size (splitter-chunk-size splitter)
        :heading-levels (splitter-heading-levels splitter)))

;;; ============================================================
;;; Semantic Splitter (Placeholder)
;;; ============================================================

(defclass semantic-splitter ()
  ((chunk-size
    :initarg :chunk-size
    :accessor splitter-chunk-size
    :initform 1000
    :type integer)

   (embedding-fn
    :initarg :embedding-fn
    :accessor splitter-embedding-fn
    :initform nil
    :documentation "Function to generate embeddings")

   (similarity-threshold
    :initarg :similarity-threshold
    :accessor splitter-similarity-threshold
    :initform 0.8
    :type float
    :documentation "Threshold for merging similar sentences"))

  (:documentation "Semantic splitter based on embedding similarity.
Note: Requires embedding function to work properly."))

(defun make-semantic-splitter (&key (chunk-size 1000) embedding-fn (similarity-threshold 0.8))
  "Create a semantic splitter."
  (make-instance 'semantic-splitter
                 :chunk-size chunk-size
                 :embedding-fn embedding-fn
                 :similarity-threshold similarity-threshold))

(defmethod split ((splitter semantic-splitter) text)
  "Split text based on semantic similarity.
Falls back to sentence splitting if no embedding function provided."
  (unless (splitter-embedding-fn splitter)
    ;; Fallback to sentence splitting
    (return-from split
      (split (make-sentence-splitter :max-chunk-size (splitter-chunk-size splitter)) text)))

  ;; Semantic splitting implementation
  (let* ((sentences (split-into-sentences text '(#\. #\! #\?)))
         (embed-fn (splitter-embedding-fn splitter))
         (threshold (splitter-similarity-threshold splitter))
         (max-size (splitter-chunk-size splitter))
         (embeddings (mapcar embed-fn sentences))
         (chunks nil)
         (current-chunk "")
         (prev-embedding nil))

    (loop for sentence in sentences
          for embedding in embeddings
          do (let ((should-split
                    (and prev-embedding
                         (< (cosine-similarity prev-embedding embedding) threshold))))
               (when (or should-split
                         (> (+ (length current-chunk) (length sentence)) max-size))
                 (when (> (length current-chunk) 0)
                   (push current-chunk chunks))
                 (setf current-chunk ""))
               (setf current-chunk
                     (if (> (length current-chunk) 0)
                         (concatenate 'string current-chunk " " sentence)
                         sentence))
               (setf prev-embedding embedding)))

    (when (> (length current-chunk) 0)
      (push current-chunk chunks))

    (nreverse chunks)))

(defmethod splitter-metadata ((splitter semantic-splitter))
  (list :type :semantic
        :chunk-size (splitter-chunk-size splitter)
        :threshold (splitter-similarity-threshold splitter)))

;;; ============================================================
;;; Convenience Factory
;;; ============================================================

(defun make-splitter (type &rest args)
  "Factory function to create splitters by type.

Parameters:
  TYPE - Splitter type (:fixed, :sentence, :paragraph, :recursive,
                        :code, :markdown, :semantic)
  ARGS - Arguments passed to the specific constructor

Returns:
  Splitter instance"
  (apply (case type
           (:fixed #'make-fixed-size-splitter)
           (:sentence #'make-sentence-splitter)
           (:paragraph #'make-paragraph-splitter)
           (:recursive #'make-recursive-splitter)
           (:code #'make-code-splitter)
           (:markdown #'make-markdown-splitter)
           (:semantic #'make-semantic-splitter)
           (otherwise (error "Unknown splitter type: ~A" type)))
         args))

